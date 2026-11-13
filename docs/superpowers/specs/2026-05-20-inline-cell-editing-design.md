# Inline Cell Editing — 行内编辑设计

- 日期: 2026-05-20
- 状态: Draft（待用户复核）
- 作者: Claude（与 long 协同 brainstorm）
- 范围: `0505-SSHKeeper`，文件 `SSHKeeper/Features/Database/ResultGrid.swift` 及 `CellViewerSheet.swift`

## 1. 背景

当前 SSHKeeper 表格的单条数据编辑路径是：

```
双击 cell
  → 弹 CellViewerSheet（查看模式）
  → 点 “编辑” 按钮
  → 进入 TextEditor
  → 点 “保存”
  → sheet 关闭
```

5 步动作改 1 个值，与 Tableplus / Sequel Pro 等同类工具的"双击直接编辑"差距明显。`DraftRowView`（插入新行）已经走的是行内 TextField 模式，但既存行的编辑没沿用这套范式。

## 2. 目标

把现有行的 cell 编辑改造成行内编辑（in-place editing）：

1. 双击 cell → cell 当场变成 `TextField`，焦点自动落入
2. 回车或失焦提交（值变了才发 SQL）
3. Esc 取消
4. Tab / Shift+Tab 在同行可编辑列之间跳转 + 提交
5. 右键菜单提供"设为 NULL"
6. 保存中显示 ProgressView；失败留态显错

`CellViewerSheet.swift` 整个删除。本期不引入大字段查看器，长字段在 TextField 内横向滚动；后期需要再开独立 issue。

## 3. 非目标

- 整行编辑（一次 UPDATE 多列）
- 跨行 Tab 连续编辑
- 大字段专用查看器 / JSON pretty 视图
- 撤销栈 / 编辑历史

## 4. 行为规约

| 触发 | 行为 |
|---|---|
| 双击非主键 cell（`editConfig` 非 nil） | 进入编辑态，TextField 获得焦点（光标在末尾；不强求全选——SwiftUI 原生 `TextField` 全选需要 NSViewRepresentable 包裹，本期不上） |
| 双击主键列 | 不响应（cell 保持只读） |
| 双击但 `editConfig == nil` | 不响应（查询结果无可定位主键） |
| 回车 | 值与 originalValue 不同 → 调 `onCellEdit` 发 SQL；相同 → 直接退出编辑态 |
| TextField 失焦 | 同回车 |
| Esc | 恢复原值（不发 SQL）；退出编辑态 |
| Tab | 提交当前；找同行下一可编辑列（跳过主键 / auto_increment）进入编辑；到边界则退出 |
| Shift+Tab | 同上，反向 |
| 右键 "设为 NULL"（仅 nullable 列显示该菜单项） | draft 切到 `.null`，cell 显示 `NULL` 灰字；下次提交发 `NULL` |
| 右键 "取消 NULL" | draft 切回 `.text("")` |
| 保存进行中 | TextField 禁用 + cell 右侧叠加 ProgressView |
| 保存失败 | 不退出编辑态；当前编辑 cell（仅这一格）加红色边框；顶部 banner 显示 `error.localizedDescription`（同 `draftToolbar` 风格） |

> nullable 信息来源：`editConfig` 当前没暴露列定义。本期需要给 `EditConfig` 加一个 `columnDefs: [ColumnDefinition]?`（沿用 `DraftConfig` 已有的字段），从父层 `TableInspectorPane` 注入；缺失则不显示 "设为 NULL" 菜单（fail-closed）。
| 编辑态下点别处 cell | 当前 cell 走"失焦提交"；若提交成功，新 cell 进入编辑态；若失败，留在当前 cell 报错 |

### 4.1 与既有 `draftConfig`（插入新行）的关系

行内编辑（修改现有行）与 `draftConfig`（插入新行）状态独立。同一时刻允许：

- 草稿插入中 + 编辑某既有行 cell：两者各自独立处理回车/Esc
- Esc 优先级：先取消编辑 cell，再取消草稿（在 `keyboardShortcutRouter` 内做优先级排序）

## 5. 架构

方案 B：顶层集中状态。

```
ResultGrid
├── @State editingCell: EditingCell?           // 当前编辑 cell（含 rowIdx/col/originalValue）
├── @State editingDraft: EditingDraft          // .text(String) | .null
├── @State editError: String?
├── @State editIsSaving: Bool
│
├── inlineEditBanner (仅 editingCell != nil 时显示)
│   - 风格复用 draftToolbar：图标 + 提示 + 错误 + ProgressView
│
└── ForEach rows → ResultRowView (新增 props):
        editingCol: Int?
        editingDraft: EditingDraft?
        editIsSaving: Bool
        editError: String?  // 仅在该行的编辑 cell 显示红框时用
        onBeginEdit: (rowIdx, col, originalValue) → Void
        onDraftChange: (String) → Void
        onSetNull: () → Void
        onClearNull: () → Void
        onCommit: () → Void
        onCancel: () → Void
        onTabNav: (forward: Bool) → Void
```

## 6. 新增类型

```swift
struct EditingCell: Equatable {
    let rowIdx: Int
    let col: Int
    let originalValue: String?
}

enum EditingDraft: Equatable {
    case text(String)
    case null

    var asNewValue: String? {
        switch self {
        case .text(let s): return s
        case .null: return nil
        }
    }
}
```

## 7. 关键方法（`ResultGrid` 内）

```swift
private func beginEdit(rowIdx: Int, col: Int, originalValue: String?) {
    // 主键列 / editConfig == nil 时调用方就不该传过来；这里再守一次
    guard let cfg = editConfig else { return }
    let columnName = result.columns[col]
    guard !cfg.pkColumns.contains(columnName) else { return }
    editingCell = EditingCell(rowIdx: rowIdx, col: col, originalValue: originalValue)
    editingDraft = (originalValue == nil) ? .null : .text(originalValue!)
    editError = nil
    editIsSaving = false
}

private func cancelEdit() {
    editingCell = nil
    editingDraft = .text("")
    editError = nil
    editIsSaving = false
}

private func commitEditIfChanged() async {
    guard let cell = editingCell, let cfg = editConfig else { return }
    let newValue = editingDraft.asNewValue
    if newValue == cell.originalValue {
        cancelEdit()
        return
    }
    guard cell.rowIdx < cachedRows.count else { cancelEdit(); return }
    let snapshotRow = cachedRows[cell.rowIdx]
    let columnName = result.columns[cell.col]
    editIsSaving = true
    editError = nil
    do {
        try await cfg.onCellEdit(snapshotRow, columnName, newValue)
        cancelEdit()
    } catch {
        editError = error.localizedDescription
        editIsSaving = false
        // 不退出编辑态
    }
}

private func tabNav(forward: Bool) {
    // 在 commit 之前快照位置；commit 成功会把 editingCell 清掉
    guard let pinned = editingCell else { return }
    Task {
        await commitEditIfChanged()
        // 失败：editingCell 仍是 pinned，editError 非 nil → 不跳
        if editError != nil { return }
        if let next = findNextEditableCol(from: pinned.col, in: pinned.rowIdx, forward: forward) {
            let originalValue = cachedRows[safe: pinned.rowIdx]?[safe: next] ?? nil
            beginEdit(rowIdx: pinned.rowIdx, col: next, originalValue: originalValue)
        }
        // 边界：commit 已经 cancelEdit 过了，啥也不用做
    }
}

private func findNextEditableCol(from: Int, in rowIdx: Int, forward: Bool) -> Int? {
    guard let cfg = editConfig else { return nil }
    let range = forward ? (from + 1)..<result.columns.count : 0..<from
    let candidates = forward ? Array(range) : Array(range).reversed()
    return candidates.first { col in
        let name = result.columns[col]
        return !cfg.pkColumns.contains(name)
    }
}
```

> 注：`commitEditIfChanged` 失败后 `editingCell` 不动；`tabNav` 通过检查 `editError == nil` 来决定是否真的跳到下一列。

## 8. `ResultRowView` 改造

- cell 渲染时判断 `col == editingCol`：
  - 命中：渲染 `TextField` + `@FocusState`；`disabled(editIsSaving)`；红框 = `editError != nil`；右侧 overlay ProgressView when saving
  - 未命中：维持现有 `Text`
- `==` 实现里把 `editingCol`、`editIsSaving`、`editError != nil`（用 Bool 镜像，闭包不参与）纳入比较
- `RowClickRouter.onDoubleClick`：从原来调 `onDoubleTap(rowIdx, col, value)` 改为调 `onBeginEdit(rowIdx, col, originalValue)`
- contextMenu 多加一组 "设为 NULL" / "取消 NULL"（仅在该行的编辑 cell 在本行时显示）

## 9. 删除项

- `CellViewerSheet.swift` 整个文件（含 `CellPresentation`、`CellViewerSheet`）
- `ResultGrid` 的：
  - `@State private var presentedCell: CellPresentation?`
  - `.sheet(item: $presentedCell)` 块
  - `handleCellDoubleTap`（被 `beginEdit` 取代）

grep 确认 `CellViewerSheet` / `CellPresentation` 在仓库内仅 `ResultGrid.swift` 和 `CellViewerSheet.swift` 两处引用，删除安全。

## 9.1 父层注入（`TableInspectorPane.swift`）

`contentEditConfig(for:)` 内已经持有 `let cols = session.inspector.currentColumnDefinitions() ?? []`，新增字段 `columnDefs: cols` 注入 `EditConfig` 即可（与现有 `DraftConfig` 注入路径同款，无需新接口）。

`EditConfig` 同步加 `let columnDefs: [ColumnDefinition]` 字段；空数组时 `ResultRowView` 的"设为 NULL"菜单不显示（fail-closed）。

## 10. 错误处理

- `onCellEdit` throws → `editError = error.localizedDescription`
- 错误显示在 `inlineEditBanner`（顶部）+ cell 红色边框
- 错误显示之后用户行为：改值再回车（重新 commit）/ Esc 放弃
- 错误信息走现有 `DatabaseErrorTranslator`，无需新增翻译逻辑

## 11. 焦点 / 键盘细节

- TextField 进入编辑态时通过 `@FocusState` 立刻获得焦点；初始光标在末尾、文本全选
- Esc 通过 `keyboardShortcutRouter` 路由：
  - `editingCell != nil` → cancelEdit
  - else if `draftConfig != nil` → draft.onCancel
- `⌘C` / `⌘V` 的 selectedRow 行级操作在编辑态下仍然走 TextField 的内置行为（first responder 优先）
- Tab / Shift+Tab 由 TextField 默认行为接管：通过 `.onSubmit` 不够，需要自定义按键处理。最简做法：用 `NSViewRepresentable` 包一个 `NSTextField` 也太重；可以走 SwiftUI `.onKeyPress(.tab)` + `.onKeyPress(.tab, phases: .down, action:)` 在 macOS 14+ 支持。**待实现时验证 macOS 14 上 `.onKeyPress` 的可用性**；若不可行，退化为 "Tab 只提交不跳列"，并在 spec 跟进里改回。

## 12. 测试

`SSHKeeperTests` 现有结构待查。下列至少手动验证：

1. 双击非主键 cell → TextField 出现、焦点在内、文本全选
2. 改值回车 → SQL 发出、cell 还原 Text 显示新值
3. 改值后 Esc → cell 还原 Text 显示原值，没有 SQL
4. 不改值回车 → 直接退出，没有 SQL
5. 双击主键列 → 无反应
6. 双击 + 失焦（鼠标点别行）→ 走提交
7. 改值 → 服务端 reject → cell 红框 + 顶部 banner，Esc 可放弃
8. 右键 "设为 NULL" → cell 显 NULL 灰字 → 回车 → 发 UPDATE ... = NULL
9. Tab → 同行下一列；最后一列 → 退出
10. Shift+Tab → 同行上一列；第一列 → 退出
11. `editConfig == nil`（无主键表 / 多表 join 结果）→ 双击无反应
12. 草稿插入新行 + 同时双击既有行 cell：两者状态独立、Esc 优先取消编辑

回归确认：

- 已有的 `DraftRowView`（插入新行）不受影响
- 行级 `selectedRowIdx`、⌘C/⌘V、右键复制行 等不受影响
- 排序、列宽拖拽、CSV/TSV 导出不受影响

## 13. 不在本次范围（备忘）

- 大字段查看器：删 sheet 后长 JSON / 文本只能在 TextField 横向滚动，用户体验下降；如反馈强烈，开独立 issue 引入 "查看完整内容…" 右键项 + 只读 sheet
- 整行 / 批量编辑：需重做 `editConfig.onCellEdit` 接口
- 编辑历史 / 撤销栈：暂无需求

## 14. 风险

| 风险 | 缓解 |
|---|---|
| `.onKeyPress(.tab)` 在 macOS 14 上行为不一致 | 实现时验证；不可用则降级为 Tab 仅提交不跳列，并在 spec 标注跟进 |
| TextField 失焦提交在滚动 / 窗口失活时被误触发 | originalValue 比对兜底（值没变就不发 SQL）；ScrollView 滚动通常不会让 TextField 失焦 |
| 长文本字段（CLOB / JSON）显示不便 | 已知非目标；后期独立 issue |
| 提交并发：失焦 + Tab 同时触发 | `editIsSaving` 守门，进入态后再次提交直接 return |
