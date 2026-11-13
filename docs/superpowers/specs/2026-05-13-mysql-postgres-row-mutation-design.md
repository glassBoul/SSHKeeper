# Spec — MySQL / Postgres 行级增删（insertRow / deleteRow）

- 日期：2026-05-13
- 范围：MySQL 与 Postgres，单行 INSERT 与 DELETE
- 不在范围：批量增删、撤销、CSV 导入、类型化输入控件

## 1. 背景与现状

- `DatabaseClient` 协议已有 `updateRow(table, primaryKey, column, value)`，MySQL 与 Postgres 各自实现。
- 「内容」tab 通过 `ResultGrid` 双击单元格 + `CellViewerSheet` 完成单元格编辑，回调链 `editConfig.onCellEdit → TableInspectorState.updateRow → DatabaseClient.updateRow`。
- 行右键菜单当前只有「复制行 (TSV) / 复制行 (CSV) / 复制为 INSERT」。
- 没有行级 INSERT / DELETE 入口。

## 2. 协议层

`SSHKeeperCore/Features/Database/DatabaseClient.swift` 增加两个方法：

```swift
/// 插入一行。`values` 的 key 为列名（与 ColumnDefinition.name 一致），
/// 值用 `String?` 表达（nil = NULL）。AUTO_INCREMENT 列、想走 DEFAULT 的列
/// 应不在 `values` 中出现 —— SQL 不写该列，由 DB 兜默认值/自增。
func insertRow(_ table: DatabaseObject, values: [String: String?]) async throws

/// 按主键删除一行。沿用 updateRow 的硬约束：无主键直接 throw。
/// MySQL 内部加 LIMIT 1 防 PK 错选误删大量行；PG 不加（不支持），
/// 靠 PK 唯一性保证。
func deleteRow(_ table: DatabaseObject, primaryKey: [String: String]) async throws
```

设计选择：
- `values: [String: String?]` 而非 `[ColumnDefinition]` — 客户端层只关心列名 + 值，类型校验交给 DB
- `String?` 双层语义 — 不在 dict = 不写入列；在 dict 但 nil = `NULL`；在 dict 且非空 = 具体值
- `primaryKey: [String: String]` — 与 `updateRow` 完全对齐

## 3. MySQL 实现

`SSHKeeperCore/Features/Database/MySQLDatabaseClient+Mutation.swift` 末尾追加：

```swift
public func insertRow(_ table: DatabaseObject, values: [String: String?]) async throws {
    let (sql, bindings) = try insertSQL(table, values: values)
    _ = try await runQuery(sql, bindings: bindings)
}

internal func insertSQL(
    _ table: DatabaseObject,
    values: [String: String?]
) throws -> (sql: String, bindings: [QueryValue]) {
    guard !values.isEmpty else {
        throw DatabaseClientError.invalidConfiguration("至少要提供一列的值")
    }
    let qualified = qualifiedName(table)
    let keys = values.keys.sorted()  // 稳定顺序便于测试
    let cols = keys.map { SQLIdentifier.mysql($0) }.joined(separator: ", ")
    let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
    let bindings: [QueryValue] = keys.map { values[$0]!.map { .string($0) } ?? .null }
    return ("INSERT INTO \(qualified) (\(cols)) VALUES (\(placeholders))", bindings)
}

public func deleteRow(_ table: DatabaseObject, primaryKey: [String: String]) async throws {
    let (sql, bindings) = try deleteSQL(table, primaryKey: primaryKey)
    _ = try await runQuery(sql, bindings: bindings)
}

internal func deleteSQL(
    _ table: DatabaseObject,
    primaryKey: [String: String]
) throws -> (sql: String, bindings: [QueryValue]) {
    guard !primaryKey.isEmpty else {
        throw DatabaseClientError.invalidConfiguration("无主键，无法定位行；请通过 SQL 编辑器 DELETE")
    }
    let qualified = qualifiedName(table)
    let sortedKeys = primaryKey.keys.sorted()
    let whereExpr = sortedKeys.map { "\(SQLIdentifier.mysql($0)) = ?" }.joined(separator: " AND ")
    let bindings: [QueryValue] = sortedKeys.map { .string(primaryKey[$0]!) }
    return ("DELETE FROM \(qualified) WHERE \(whereExpr) LIMIT 1", bindings)
}
```

把 SQL 构建抽成 `internal` 函数是为了让 `RowMutationSQLTests` 可以脱离真实连接测试字符串。

## 4. Postgres 实现

`SSHKeeperCore/Features/Database/PostgresDatabaseClient.swift` 追加两个方法，形状对齐：

```swift
public func insertRow(_ table: DatabaseObject, values: [String: String?]) async throws {
    guard !values.isEmpty else {
        throw DatabaseClientError.invalidConfiguration("至少要提供一列的值")
    }
    let (schema, name) = Self.splitQualifiedName(table)
    let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
    let keys = values.keys.sorted()
    let cols = keys.map { SQLIdentifier.postgres($0) }.joined(separator: ", ")
    let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
    let bindings: [QueryValue] = keys.map { values[$0]!.map { .string($0) } ?? .null }
    _ = try await runQuery(
        "INSERT INTO \(qualified) (\(cols)) VALUES (\(placeholders))",
        bindings: bindings
    )
}

public func deleteRow(_ table: DatabaseObject, primaryKey: [String: String]) async throws {
    guard !primaryKey.isEmpty else {
        throw DatabaseClientError.invalidConfiguration("无主键，无法定位行；请通过 SQL 编辑器 DELETE")
    }
    let (schema, name) = Self.splitQualifiedName(table)
    let qualified = "\(SQLIdentifier.postgres(schema)).\(SQLIdentifier.postgres(name))"
    let sortedKeys = primaryKey.keys.sorted()
    let whereExpr = sortedKeys.map { "\(SQLIdentifier.postgres($0)) = ?" }.joined(separator: " AND ")
    let bindings: [QueryValue] = sortedKeys.map { .string(primaryKey[$0]!) }
    _ = try await runQuery(
        "DELETE FROM \(qualified) WHERE \(whereExpr)",
        bindings: bindings
    )
}
```

PG 与 MySQL 差异：
- `SQLIdentifier.postgres` + `splitQualifiedName(schema.table)`
- `DELETE` 不加 `LIMIT`（PG 不支持），靠 PK 唯一性保证仅删一行 — 与现有 `updateRow` PG 实现一致的 trade-off
- `?` → `$N` 翻译由 `runQuery(_:bindings:)` 内部处理（复用 `QueryValue.mysqlPlaceholdersToPostgres`）

## 5. State 层

`SSHKeeper/Features/Database/TableInspectorState.swift` 在 `updateRow` 旁添加：

```swift
func insertRow(values: [String: String?]) async throws {
    guard let client, let table = selectedTable else { return }
    try await client.insertRow(table, values: values)
    invalidateContentCaches(for: table.id)
    await loadInspector(tab: .content)
}

func deleteRow(primaryKey: [String: String]) async throws {
    guard let client, let table = selectedTable else { return }
    try await client.deleteRow(table, primaryKey: primaryKey)
    invalidateContentCaches(for: table.id)
    await loadInspector(tab: .content)
}

private func invalidateContentCaches(for tableID: String) {
    for key in inspectorResults.keys where key.hasPrefix("\(tableID):content:") {
        inspectorResults.removeValue(forKey: key)
        inspectorErrors.removeValue(forKey: key)
    }
    contentRowCount.removeValue(forKey: tableID)
    contentRowCountTimedOut.remove(tableID)
}
```

同时把 `updateRow` 现有的失效代码替换成调用 `invalidateContentCaches(for:)` —— 这是 brainstorming 允许的「修改路径上的小重构」，不属于无关清理。

不实现：插入后自动跳到新行所在页（MySQL/PG 拿新行位置策略不一致），当前页 reload 后行数 +1 已足够反馈。

## 6. UI

### 6.1 `ResultGrid.EditConfig` 扩展

```swift
struct EditConfig {
    let pkColumns: Set<String>
    let onCellEdit: ([String?], String, String?) async throws -> Void
    let onRowDelete: ([String?]) async throws -> Void
    let onRowInsert: () -> Void
}
```

- `onRowDelete(row)`：闭包内部根据 `pkColumns` 从 `row` 抽出 PK 字典 → 调 `state.deleteRow`
- `onRowInsert()`：触发父层 sheet（仅做 UI 路由，不带数据）

### 6.2 `ResultGrid` 行右键菜单

仅当 `editConfig != nil`（有主键）时显示底部 2 项：

```
复制行 (TSV)
复制行 (CSV)
复制为 INSERT
─────────────
插入新行...
删除此行...        ⌘⌫
```

- 「删除此行」绑 `keyboardShortcut(.delete, modifiers: .command)` — macOS 删除惯例
- 不绑单键 Delete — 避免在筛选输入框失焦后误触

### 6.3 `TableInspectorPane` 工具条

将「+ 新增行」按钮加到 `paginationFooter` 同一行的右侧（紧邻「每页」picker 之前）：

```
[<]  第 1 / 9 页 · 共 1730 行  [>]      [+ 新增行]   每页 [200 ▾]
```

「+ 新增行」永远可见可用（INSERT 无需 PK 定位）。

### 6.4 删除确认 confirmationDialog

挂在 `TableInspectorPane`，状态：

```swift
@State private var pendingDelete: PendingDelete?
struct PendingDelete: Identifiable {
    let id = UUID()
    let primaryKey: [String: String]
    let tableLabel: String  // qualified name
}
```

```
确认删除这一行吗？

  public.users (id = 4123)

「删除」操作不可撤销。

[取消]  [删除]   ← .destructive 角色
```

- ESC 取消；Enter 不绑（防误删）
- 删除按钮文本显示主键列名 = 值
- 错误用现有 `inspectorErrors` 渠道展示，不再叠加 alert

## 7. RowInsertSheet（新文件）

路径：`SSHKeeper/Features/Database/RowInsertSheet.swift`

风格对齐 `ColumnEditorSheet`。

输入：`[ColumnDefinition]`（从 `inspector.currentColumnDefinitions()` 拿；未缓存时显示 ProgressView 同时 `await loadColumnDefinitions()`）。

每列三态：

```swift
enum FieldMode: Equatable {
    case useDefault      // 不写入 values，让 DB 走默认值 / 自增
    case null            // values[name] = .some(nil)
    case value(String)   // values[name] = .some(.some(s))
}
```

**初值规则**：
| 列特征 | 初始 mode |
|---|---|
| `isAutoIncrement == true` | `useDefault`（整行禁用，不让改） |
| `defaultValue` 非空 | `useDefault` |
| `nullable && defaultValue == nil` | `null` |
| `!nullable && defaultValue == nil` | `value("")` |

**前端校验**（实时；错误时禁用「插入」按钮，红字提示）：
- `!column.nullable` 且 `mode == .null` → "此列 NOT NULL，不能为 NULL"
- `!column.nullable && !column.isAutoIncrement && column.defaultValue == nil` 且 `mode == .useDefault` → "此列没有默认值，必须提供"

不做客户端类型校验 — 类型/长度/枚举/约束让 DB 报，错误透传到 sheet 内的错误行，sheet 不关闭让用户改完重试。

**提交流程**：
1. 折叠 `[String: FieldMode]` → `[String: String?]`（剔除 `useDefault`）
2. 调 `inspector.insertRow(values:)`
3. 成功 → 关 sheet；失败 → 错误行显示 `error.localizedDescription`，sheet 保持

## 8. 测试

新文件 `SSHKeeperTests/RowMutationSQLTests.swift`，纯 SQL 字符串测试，不连真实数据库。模式对齐现有 `SQLEscapeTests` / `QueryValueTests`。

调用入口：`MySQLDatabaseClient.insertSQL / deleteSQL`（internal 暴露给测试）+ 给 Postgres 同样补一对 internal 构建函数。

用例矩阵：

| Case | MySQL | Postgres |
|---|---|---|
| `insertRow` 多列正常 | sql/bindings 一致；列名按 key 排序 | 同左，identifier 用 `"..."` |
| `insertRow` 单列 NULL | `bindings == [.null]`；占位仍在 | 同左 |
| `insertRow` 空 dict | throw `invalidConfiguration` | 同左 |
| `insertRow` 列名含特殊字符 | `` `a``b` `` 转义生效 | `"a""b"` 转义生效 |
| `deleteRow` 单 PK | `DELETE ... WHERE \`id\` = ? LIMIT 1` | `DELETE ... WHERE "id" = ?`（无 LIMIT） |
| `deleteRow` 复合 PK | WHERE 多 AND，按 key 排序稳定 | 同左 |
| `deleteRow` 空 PK | throw `invalidConfiguration` | 同左 |

不写集成测试 — 与现有 `MySQLDatabaseClient+Mutation.swift` 一致：现有所有 mutation 也都没有连库测试。补集成测试是更大独立工作，不属于本 spec 范围。

## 9. 不做什么

- 批量插入 / 批量删除（需给 `ResultGrid` 加多选模型）
- 撤销 / undo
- 插入后跳到新行所在页
- DELETE 影响行数 > 1 的客户端回滚（让 DB 自己报）
- CSV / 多行粘贴导入
- RowInsertSheet 类型化控件（日期 / 布尔 / JSON 编辑器）
- PG schema 选择 UI（沿用 `splitQualifiedName`）

## 10. 文件改动清单

- 改：`SSHKeeperCore/Features/Database/DatabaseClient.swift` — 协议两个新方法
- 改：`SSHKeeperCore/Features/Database/MySQLDatabaseClient+Mutation.swift` — 两个 public + 两个 internal SQL 构建器
- 改：`SSHKeeperCore/Features/Database/PostgresDatabaseClient.swift` — 两个 public + 配套 internal SQL 构建器
- 改：`SSHKeeper/Features/Database/TableInspectorState.swift` — 两个方法 + 抽出 `invalidateContentCaches`
- 改：`SSHKeeper/Features/Database/ResultGrid.swift` — `EditConfig` 加 2 个闭包，行右键 + 快捷键
- 改：`SSHKeeper/Features/Database/TableInspectorPane.swift` — paginationFooter 加按钮，新增 sheet presentation，删除 confirmationDialog，扩 `contentEditConfig`
- 新：`SSHKeeper/Features/Database/RowInsertSheet.swift`
- 新：`SSHKeeperTests/RowMutationSQLTests.swift`
