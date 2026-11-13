# Inline Cell Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 SSHKeeper 数据库表格的"双击 cell → 弹 sheet → 点编辑 → 改 → 点保存"流程，改成"双击 cell → 行内 TextField → 回车/失焦提交"的就地编辑；删除 CellViewerSheet。

**Architecture:** 顶层集中状态。`ResultGrid` 持有 `editingCell / editingDraft / editError / editIsSaving`；`ResultRowView` 接收编辑态 props，命中的 cell 渲染 `TextField + @FocusState`，否则维持现有 `Text`。提交走既有 `EditConfig.onCellEdit` 通道；失败留态显错。

**Tech Stack:** SwiftUI (macOS 14)、Swift 6、SwiftTerm 无关、纯 App target 改动；不引入新依赖。

**Repository note:** 当前工作目录非 git 仓库（`git status` 失败），所以不做 `git commit`。每个 Task 末尾的「Verify」步骤代替 commit 作为里程碑。

**Reference spec:** `docs/superpowers/specs/2026-05-20-inline-cell-editing-design.md`

**Testing note:** SwiftUI 视图状态 + FocusState 难做单测；项目现有 UI 层（ResultGrid 等）也无单测；本 plan 走"编译通过 + 手动验证清单"作为每个 Task 的 Verify 步骤。纯函数（`findNextEditableCol`）足够简单，加单测的工程收益低于改 test target 依赖的成本，省略。

**Build/Verify 命令模板（每个 Task 末尾用）：**

```bash
cd .
xcodegen generate >/dev/null
xcodebuild build \
  -project SSHKeeper.xcodeproj \
  -scheme SSHKeeper \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -quiet
```

期望：`** BUILD SUCCEEDED **`

---

## File Structure（涉及文件一览）

修改：
- `SSHKeeper/Features/Database/ResultGrid.swift` — 顶层状态 / 编辑 banner / 路由 / `ResultRowView` 改造（同一文件）
- `SSHKeeper/Features/Database/TableInspectorPane.swift` — `contentEditConfig(for:)` 注入 `columnDefs`

删除：
- `SSHKeeper/Features/Database/CellViewerSheet.swift` — 整个文件

不动：
- `SSHKeeperCore/*` — 无改动
- 其他 Database/* 文件 — 无改动

---

### Task 1: 在 `ResultGrid` 加 `EditingCell` / `EditingDraft` 类型

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift`（在 `ResultGrid` struct 上方加类型定义；或放在 ResultGrid 内部作为嵌套类型）

- [ ] **Step 1: 在 `ResultGrid.swift` 顶部 import 之后、`struct ResultGrid` 之前，加两个类型**

打开 `SSHKeeper/Features/Database/ResultGrid.swift`，在 `import SSHKeeperCore` 之后、`struct ResultGrid: View {` 之前插入：

```swift
/// 行内编辑：当前正在编辑的 cell 位置 + 原始值。
/// originalValue 用于 commit 前判 "值变了" 才发 SQL。
struct InlineEditingCell: Equatable {
    let rowIdx: Int
    let col: Int
    let originalValue: String?
}

/// 行内编辑的草稿值。
/// .text 是用户在 TextField 里的当前输入；.null 是 "设为 NULL" 状态（cell 显示 NULL 灰字）。
enum InlineEditingDraft: Equatable {
    case text(String)
    case null

    /// 提交时转成 onCellEdit 的 newValue 参数：.text → 字符串；.null → nil。
    var asNewValue: String? {
        switch self {
        case .text(let s): return s
        case .null: return nil
        }
    }
}
```

> 用 `Inline` 前缀避免和 `Cell` / `Editing` 这些泛名字冲突。

- [ ] **Step 2: 验证编译**

Run 上方 Build 命令模板。

Expected: `** BUILD SUCCEEDED **`

---

### Task 2: 给 `EditConfig` 加 `columnDefs` 字段；父层 `TableInspectorPane` 注入

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (around line 11-21, `struct EditConfig`)
- Modify: `SSHKeeper/Features/Database/TableInspectorPane.swift` (around line 148, `ResultGrid.EditConfig(...)` 构造处)

- [ ] **Step 1: 给 `EditConfig` 加 `columnDefs` 字段**

在 `ResultGrid.swift` 的 `struct EditConfig {` 块内，在 `let pkColumns: Set<String>` 下一行添加：

```swift
let pkColumns: Set<String>
/// 用于行内编辑右键菜单决定 "设为 NULL" 是否可见（只有 nullable 列才显示）。
/// 父层 TableInspectorPane 注入；空数组时所有 "设为 NULL" 菜单都不显示（fail-closed）。
let columnDefs: [ColumnDefinition]
let onCellEdit: ([String?], String, String?) async throws -> Void
```

- [ ] **Step 2: 在 `TableInspectorPane.swift` 的 `contentEditConfig` 内注入**

在 `TableInspectorPane.swift` 找到 `return ResultGrid.EditConfig(` 那一行（约 line 148）。当前代码是：

```swift
return ResultGrid.EditConfig(
    pkColumns: pkNames,
    onCellEdit: { row, columnName, newValue in
```

改成：

```swift
return ResultGrid.EditConfig(
    pkColumns: pkNames,
    columnDefs: cols,
    onCellEdit: { row, columnName, newValue in
```

（`cols` 在该函数内 line ~142 已声明：`let cols = session.inspector.currentColumnDefinitions() ?? []`，直接用）

- [ ] **Step 3: 验证编译**

Run Build。

Expected: `** BUILD SUCCEEDED **`

---

### Task 3: `ResultGrid` 添加编辑态 `@State` 字段

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (around line 41-49, 现有 `@State` 字段块)

- [ ] **Step 1: 在 `ResultGrid` 的 `@State` 字段尾部新增 4 个字段**

定位 `ResultGrid.swift` 的 `@State private var selectedRowIdx: Int? = nil` 那一行（约 line 48）。在它下面新增：

```swift
    @State private var selectedRowIdx: Int? = nil
    @State private var editingCell: InlineEditingCell? = nil
    @State private var editingDraft: InlineEditingDraft = .text("")
    @State private var editError: String? = nil
    @State private var editIsSaving: Bool = false
```

- [ ] **Step 2: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`（暂时未使用，会有 "variable was never used" 警告；忽略）

---

### Task 4: `ResultGrid` 添加 `beginEdit / cancelEdit / commitEditIfChanged / findNextEditableCol / tabNav` 5 个方法

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (在 `private func handleCellDoubleTap` 上方新增方法块)

- [ ] **Step 1: 在 `handleCellDoubleTap` 函数前新增方法块**

定位 `private func handleCellDoubleTap(rowIdx: Int, col: Int, value: String?) {` 那一行（约 line 351）。在它**之前**插入：

```swift
    // MARK: - 行内编辑（in-place cell editing）

    /// 由 ResultRowView 双击 cell 时触发。
    /// 主键列 / editConfig 缺失 → 守门拦下不进入编辑态。
    private func beginEdit(rowIdx: Int, col: Int, originalValue: String?) {
        guard let cfg = editConfig else { return }
        guard col < result.columns.count else { return }
        let columnName = result.columns[col]
        guard !cfg.pkColumns.contains(columnName) else { return }
        editingCell = InlineEditingCell(rowIdx: rowIdx, col: col, originalValue: originalValue)
        // 永远以 .text 进入，让 TextField 一定 mount → 键盘 / focus / 提交链路始终生效。
        // 原值是 NULL 也用 .text("") 起步；用户要保留 NULL 走 Esc，要重新设 NULL 走右键菜单。
        // 副作用：原值是 NULL 时双击 + 回车（空字符串）会发 SET col = ''，与"什么都没改"语义不同；
        // 这是 spec 里"回车提交（值变了才发 SQL）"的直接推论，"" ≠ nil。
        editingDraft = .text(originalValue ?? "")
        editError = nil
        editIsSaving = false
    }

    /// Esc / 提交成功 / 边界 Tab 退出编辑态。
    private func cancelEdit() {
        editingCell = nil
        editingDraft = .text("")
        editError = nil
        editIsSaving = false
    }

    /// 提交：值变了才发 SQL；没变直接退出。
    /// 失败留态：editingCell 不动、editError 非空、editIsSaving 复位；UI 显红框 + 顶部 banner。
    @MainActor
    private func commitEditIfChanged() async {
        guard let cell = editingCell, let cfg = editConfig else { return }
        let newValue = editingDraft.asNewValue
        if newValue == cell.originalValue {
            cancelEdit()
            return
        }
        guard cachedRows.indices.contains(cell.rowIdx) else { cancelEdit(); return }
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
        }
    }

    /// 在指定行内、从 from 列出发，找下一个可编辑列（跳过主键）。
    /// forward=true 向右，否则向左。找不到返回 nil。
    private func findNextEditableCol(from: Int, in rowIdx: Int, forward: Bool) -> Int? {
        guard let cfg = editConfig else { return nil }
        let cols = result.columns
        let candidates: [Int]
        if forward {
            candidates = Array((from + 1)..<cols.count)
        } else {
            candidates = (0..<from).reversed()
        }
        return candidates.first { col in
            let name = cols[col]
            return !cfg.pkColumns.contains(name)
        }
    }

    /// Tab / Shift+Tab：先 commit 当前；成功则跳同行下一可编辑列；失败留在当前 cell 显错。
    private func tabNav(forward: Bool) {
        guard let pinned = editingCell else { return }
        Task {
            await commitEditIfChanged()
            if editError != nil { return }
            if let next = findNextEditableCol(from: pinned.col, in: pinned.rowIdx, forward: forward) {
                let originalValue = cachedRows.indices.contains(pinned.rowIdx)
                    ? (cachedRows[pinned.rowIdx].indices.contains(next) ? cachedRows[pinned.rowIdx][next] : nil)
                    : nil
                beginEdit(rowIdx: pinned.rowIdx, col: next, originalValue: originalValue)
            }
            // 边界：commit 已 cancelEdit 过，什么都不做
        }
    }
```

- [ ] **Step 2: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`（这些方法暂未被调用，会有 "never used" 警告；忽略）

---

### Task 5: 给 `ResultRowView` 加编辑态相关 props 和 Bool 镜像

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`struct ResultRowView` 块，约 line 741-812)

- [ ] **Step 1: 给 `ResultRowView` 新增 props 字段**

定位 `struct ResultRowView: View, Equatable {` 块内的 `let onDeleteRow: (([String?]) -> Void)?` 那一行（约 line 757）。在它**下方**新增字段（**保留**该行不动）：

```swift
    let onDeleteRow: (([String?]) -> Void)?

    // MARK: 行内编辑 props（nil = 该行不在编辑态）
    /// 当前编辑列号；非 nil 时该 cell 渲染 TextField。
    let editingCol: Int?
    /// 当前草稿；仅在 editingCol != nil 时使用。
    let editingDraft: InlineEditingDraft
    /// 保存中 → TextField disabled + 右侧 ProgressView。
    let editIsSaving: Bool
    /// 该行的编辑 cell 是否失败 → 红框。
    let editHasError: Bool
    /// 列定义（用于右键 "设为 NULL" 只在 nullable 列显示）；可能空数组。
    let editColumnDefs: [ColumnDefinition]

    let onBeginEdit: (_ rowIdx: Int, _ col: Int, _ originalValue: String?) -> Void
    let onDraftTextChange: (String) -> Void
    let onSetNull: () -> Void
    let onClearNull: () -> Void
    let onCommit: () -> Void
    let onCancelEdit: () -> Void
    let onTabNav: (_ forward: Bool) -> Void
```

- [ ] **Step 2: 更新 `init`**

在 `init(` 块（约 line 765）末尾、`self.hasDeleteHook = ...` 之后，给新字段加初始化。先在 init 参数列表内（`onDeleteRow:` 之后）追加：

```swift
        onDeleteRow: (([String?]) -> Void)?,
        editingCol: Int?,
        editingDraft: InlineEditingDraft,
        editIsSaving: Bool,
        editHasError: Bool,
        editColumnDefs: [ColumnDefinition],
        onBeginEdit: @escaping (_ rowIdx: Int, _ col: Int, _ originalValue: String?) -> Void,
        onDraftTextChange: @escaping (String) -> Void,
        onSetNull: @escaping () -> Void,
        onClearNull: @escaping () -> Void,
        onCommit: @escaping () -> Void,
        onCancelEdit: @escaping () -> Void,
        onTabNav: @escaping (_ forward: Bool) -> Void
```

在 init 函数体内 `self.hasDeleteHook = onDeleteRow != nil` 之后追加：

```swift
        self.hasDeleteHook = onDeleteRow != nil
        self.editingCol = editingCol
        self.editingDraft = editingDraft
        self.editIsSaving = editIsSaving
        self.editHasError = editHasError
        self.editColumnDefs = editColumnDefs
        self.onBeginEdit = onBeginEdit
        self.onDraftTextChange = onDraftTextChange
        self.onSetNull = onSetNull
        self.onClearNull = onClearNull
        self.onCommit = onCommit
        self.onCancelEdit = onCancelEdit
        self.onTabNav = onTabNav
```

- [ ] **Step 3: 更新 `==`，把编辑相关状态纳入比较**

定位 `nonisolated static func == (lhs: ResultRowView, rhs: ResultRowView) -> Bool {` 块。在 `lhs.hasDeleteHook == rhs.hasDeleteHook` 那一行后面添加：

```swift
    nonisolated static func == (lhs: ResultRowView, rhs: ResultRowView) -> Bool {
        lhs.rowIdx == rhs.rowIdx &&
        lhs.row == rhs.row &&
        lhs.columnWidths == rhs.columnWidths &&
        lhs.columns == rhs.columns &&
        lhs.isSelected == rhs.isSelected &&
        lhs.hasInsertHook == rhs.hasInsertHook &&
        lhs.hasCopyHook == rhs.hasCopyHook &&
        lhs.hasDeleteHook == rhs.hasDeleteHook &&
        lhs.editingCol == rhs.editingCol &&
        lhs.editingDraft == rhs.editingDraft &&
        lhs.editIsSaving == rhs.editIsSaving &&
        lhs.editHasError == rhs.editHasError
    }
```

> `editColumnDefs` 不参与 ==（变化频率低；变了通常表结构也变了，外层会重建）。闭包 props 全部不参与 ==。

- [ ] **Step 4: 验证编译**

Run Build.

Expected: **会失败** —— 调用方（`ResultGrid` body 内的 `ResultRowView(...)` 构造）少了一堆新参数。下一步修。

---

### Task 6: 在 `ResultGrid.grid` 的 `ResultRowView(...)` 构造处补全新参数

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`private var grid: some View` 内，约 line 109-123)

- [ ] **Step 1: 补全 `ResultRowView(...)` 调用**

定位 `private var grid: some View {` 内 `ResultRowView(` 构造块（约 line 109）。当前代码：

```swift
ResultRowView(
    row: cachedRows[rowIdx],
    rowIdx: rowIdx,
    columnWidths: columnWidths,
    columns: result.columns,
    isSelected: rowIdx == selectedRowIdx,
    onSelectRow: { selectedRowIdx = $0 },
    onDoubleTap: handleCellDoubleTap,
    onCopyTSV: { copyRow($0, separator: "\t") },
    onCopyCSV: { copyRow($0, separator: ",", quote: true) },
    onCopyInsert: { copyRowAsInsert($0) },
    onInsertRow: { editConfig?.onRowInsert(rowIdx) },
    onCopyRow: { editConfig?.onRowCopy($0, rowIdx) },
    onDeleteRow: editConfig?.onRowDelete
)
.equatable()
```

在 `onDeleteRow: editConfig?.onRowDelete` 这一行后追加新参数（**保留** `onDeleteRow` 行本身，仅追加）：

```swift
ResultRowView(
    row: cachedRows[rowIdx],
    rowIdx: rowIdx,
    columnWidths: columnWidths,
    columns: result.columns,
    isSelected: rowIdx == selectedRowIdx,
    onSelectRow: { selectedRowIdx = $0 },
    onDoubleTap: handleCellDoubleTap,
    onCopyTSV: { copyRow($0, separator: "\t") },
    onCopyCSV: { copyRow($0, separator: ",", quote: true) },
    onCopyInsert: { copyRowAsInsert($0) },
    onInsertRow: { editConfig?.onRowInsert(rowIdx) },
    onCopyRow: { editConfig?.onRowCopy($0, rowIdx) },
    onDeleteRow: editConfig?.onRowDelete,
    editingCol: (editingCell?.rowIdx == rowIdx) ? editingCell?.col : nil,
    // 非编辑行恒传 .text("") —— 编辑行按键时 editingDraft 频繁变，要避免触发所有行 re-render
    editingDraft: (editingCell?.rowIdx == rowIdx) ? editingDraft : .text(""),
    editIsSaving: (editingCell?.rowIdx == rowIdx) ? editIsSaving : false,
    editHasError: (editingCell?.rowIdx == rowIdx) && (editError != nil),
    editColumnDefs: editConfig?.columnDefs ?? [],
    onBeginEdit: { rIdx, col, val in beginEdit(rowIdx: rIdx, col: col, originalValue: val) },
    onDraftTextChange: { s in editingDraft = .text(s) },
    onSetNull: { editingDraft = .null },
    onClearNull: { editingDraft = .text("") },
    onCommit: { Task { await commitEditIfChanged() } },
    onCancelEdit: { cancelEdit() },
    onTabNav: { forward in tabNav(forward: forward) }
)
.equatable()
```

- [ ] **Step 2: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`（编辑功能此时还没接到 UI 上，但调用图全打通了）

---

### Task 7: `ResultRowView` body 内：cell 命中编辑态时渲染 TextField

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`ResultRowView` 的 `body` 内 `ForEach(row.indices, id: \.self) { col in ... }` 块，约 line 815-838)

- [ ] **Step 1: 在 `body` 上方新增 `@FocusState` 字段**

在 `struct ResultRowView: View, Equatable {` 内、`var body: some View {` **之前**插入：

```swift
    @FocusState private var editFocus: Bool
```

- [ ] **Step 2: 把 `ForEach(row.indices, id: \.self) { col in` 块的 `Group { if let value = row[col] { ... } else { ... } }` 改为编辑态分支**

定位 `body` 内当前的：

```swift
var body: some View {
    HStack(spacing: 0) {
        ForEach(row.indices, id: \.self) { col in
            let width = columnWidths.indices.contains(col) ? columnWidths[col] : Self.defaultWidth
            Group {
                if let value = row[col] {
                    Text(value)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.primary)
                } else {
                    Text("NULL")
                        .font(.system(size: 14, design: .monospaced).italic())
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.gray.opacity(0.12)).frame(width: 0.5)
            }
        }
    }
    .background(rowBackground)
    ...
```

改成（把现有 `Group { ... }` 改成调用一个新私有方法 `cellView(col:width:)`，便于把编辑分支封装；其它部分不动）：

```swift
var body: some View {
    HStack(spacing: 0) {
        ForEach(row.indices, id: \.self) { col in
            let width = columnWidths.indices.contains(col) ? columnWidths[col] : Self.defaultWidth
            cellView(col: col, width: width)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: width, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.gray.opacity(0.12)).frame(width: 0.5)
                }
        }
    }
    .background(rowBackground)
    ...  // 保留原 .overlay / .contentShape / RowClickRouter / .contextMenu 等
```

- [ ] **Step 3: 新增 `cellView(col:width:)` 私有方法到 `ResultRowView` 内**

在 `private var rowBackground: Color { ... }` 之前插入：

```swift
    @ViewBuilder
    private func cellView(col: Int, width: CGFloat) -> some View {
        if col == editingCol {
            editingCell(col: col)
        } else {
            displayCell(col: col)
        }
    }

    @ViewBuilder
    private func displayCell(col: Int) -> some View {
        if let value = row[col] {
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.primary)
        } else {
            Text("NULL")
                .font(.system(size: 14, design: .monospaced).italic())
                .foregroundStyle(Color.secondary.opacity(0.6))
        }
    }

    @ViewBuilder
    private func editingCell(col: Int) -> some View {
        let isNull: Bool = { if case .null = editingDraft { return true } else { return false } }()
        HStack(spacing: 4) {
            if isNull {
                Text("NULL")
                    .font(.system(size: 13, design: .monospaced).italic())
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            } else {
                TextField("", text: Binding(
                    get: {
                        if case .text(let s) = editingDraft { return s }
                        return ""
                    },
                    set: { onDraftTextChange($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .focused($editFocus)
                .disabled(editIsSaving)
                .onSubmit { onCommit() }
                .onAppear { editFocus = true }
                .onChange(of: editFocus) { _, focused in
                    // 失焦提交（commit 内部会判 "值变了才发 SQL"）
                    if !focused { onCommit() }
                }
            }
            if editIsSaving {
                ProgressView().controlSize(.mini)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .stroke(editHasError ? Color.red : Color.accentColor, lineWidth: 1)
        )
    }
```

- [ ] **Step 4: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 手动验证（手动跑 App）**

由用户在 Xcode 里 Run。**不要在此期望任何 cell 双击进入编辑态**——下一个 Task 才接通双击路由。本步只确认：

1. 数据库表格仍正常显示（未编辑态下与改造前一致）
2. 双击 cell 仍弹现有 CellViewerSheet（路由还没改）

如果两条都成立 → 通过。

---

### Task 8: 把双击路由从弹 sheet 改成 `beginEdit`；删 `presentedCell` 和 `.sheet(...)` 块

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift`

- [ ] **Step 1: 删除 `presentedCell` 状态字段**

定位 `@State private var presentedCell: CellPresentation?`（约 line 44）整行删除。

- [ ] **Step 2: 删除 `.sheet(item: $presentedCell) { cell in ... }` 块**

定位 `body` 末尾的 `.sheet(item: $presentedCell) { cell in ... }`（约 line 93-100）整段删除。

- [ ] **Step 3: 替换 `handleCellDoubleTap` 为 `beginEdit` 路由**

把 `private func handleCellDoubleTap(rowIdx: Int, col: Int, value: String?) { ... }` 这整个方法（约 line 351-371）**整段删除**。

在 `ResultRowView` 的 `onDoubleTap: handleCellDoubleTap,`（在 Task 6 已修改过的 ResultRowView 构造处）改成：

```swift
onDoubleTap: { rIdx, col, val in beginEdit(rowIdx: rIdx, col: col, originalValue: val) },
```

> 注意：`onDoubleTap` 签名是 `(Int, Int, String?) -> Void`，与 `beginEdit(rowIdx:col:originalValue:)` 参数顺序一致；用闭包桥接命名参数。

- [ ] **Step 4: 验证编译**

Run Build.

Expected: 仍 `** BUILD SUCCEEDED **`。**会有一个编译错误**：`CellPresentation` 仍被 `CellViewerSheet.swift` 文件引用，但 `ResultGrid` 不再引用 → 该文件作为独立类型还能编过，编译应仍通过。如果失败，截屏错误信息回报。

- [ ] **Step 5: 手动验证**

Run App，打开数据库内容 tab：

1. 双击非主键 cell → cell **应**变成 TextField + 蓝色边框 + 焦点在内
2. 输入字符 → cell 内显示输入文本
3. 回车 → SQL 应发出（看 SwiftTerm 日志 / 表格数据应更新；如果用 MySQL 工具看后端，应能看到 UPDATE）
4. 双击主键列 → 无反应（保持只读 Text）

如果以上 4 条成立 → 通过。失败：把行为差异回报，下一个 Task 之前修。

---

### Task 9: Esc 键路由到 `cancelEdit`（优先级高于 draftConfig.onCancel）

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`keyboardShortcutRouter`，约 line 256-273)

- [ ] **Step 1: 在 `keyboardShortcutRouter` 内加 cancelEdit 按钮**

定位 `private var keyboardShortcutRouter: some View {` 块（约 line 256）。当前代码：

```swift
@ViewBuilder
private var keyboardShortcutRouter: some View {
    ZStack {
        Button("copy-row-shortcut") { handleCopyShortcut() }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(selectedRowIdx == nil || editConfig == nil)
        Button("paste-row-shortcut") { handlePasteShortcut() }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(editConfig == nil)
        if draftConfig != nil {
            Button("cancel-draft-shortcut") { draftConfig?.onCancel() }
                .keyboardShortcut(.cancelAction)
        }
    }
    ...
```

改成（把 cancelEdit 放在 `if draftConfig != nil` 之**前**，让它优先吃掉 Esc）：

```swift
@ViewBuilder
private var keyboardShortcutRouter: some View {
    ZStack {
        Button("copy-row-shortcut") { handleCopyShortcut() }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(selectedRowIdx == nil || editConfig == nil)
        Button("paste-row-shortcut") { handlePasteShortcut() }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(editConfig == nil)
        if editingCell != nil {
            // 编辑态优先吃 Esc；不在编辑态时才让 draft 拿
            Button("cancel-edit-shortcut") { cancelEdit() }
                .keyboardShortcut(.cancelAction)
        } else if draftConfig != nil {
            Button("cancel-draft-shortcut") { draftConfig?.onCancel() }
                .keyboardShortcut(.cancelAction)
        }
    }
    ...
```

> SwiftUI `.cancelAction` 同时只能一个 Button 绑；上面用 `if/else if` 保证只有一个生效。

- [ ] **Step 2: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 手动验证**

Run App：

1. 双击 cell → 改值 → Esc → cell 恢复 Text 显示原值，无 SQL 发送 ✓
2. 同时也试：草稿插入模式下 Esc 取消草稿（既有行为不破）

---

### Task 10: 顶部行内编辑 banner（错误时显示）

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`body` 内顶部条件渲染区域)

- [ ] **Step 1: 在 `body` 内 `draftConfig` 的 toolbar 后追加 inlineEditBanner**

定位 `body` 内：

```swift
var body: some View {
    VStack(spacing: 0) {
        if result.isTruncated {
            truncationBanner
            Divider()
        }
        if let draftConfig {
            draftToolbar(draftConfig)
            Divider()
        }
        if !result.columns.isEmpty {
            gridToolbar
            Divider()
        }
        grid
    }
```

在 `if let draftConfig { ... }` 块**后**、`if !result.columns.isEmpty { ... }` 块**前**插入：

```swift
        if let draftConfig {
            draftToolbar(draftConfig)
            Divider()
        }
        if editingCell != nil {
            inlineEditBanner
            Divider()
        }
        if !result.columns.isEmpty {
            gridToolbar
            Divider()
        }
```

- [ ] **Step 2: 在 `draftToolbar` 函数下方新增 `inlineEditBanner` 计算属性**

定位 `private func draftToolbar(_ cfg: DraftConfig) -> some View { ... }`（约 line 304）末尾的 `}`。在它**之后**插入：

```swift
    /// 行内编辑提示条：常态显示快捷键提示；失败时显示红字错误。
    private var inlineEditBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.line")
                .foregroundStyle(Color.accentColor)
            Text("行内编辑中")
                .font(.caption.weight(.semibold))
            Text("· ⏎ 保存（值变才发 SQL） · ⎋ 取消 · ⇥ 下一列")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let err = editError {
                Text("· \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer()
            if editIsSaving {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }
```

- [ ] **Step 3: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 手动验证**

Run App：

1. 双击 cell → 顶部应显蓝色条 "行内编辑中 · ⏎ 保存…"
2. Esc → 条消失
3. 改值 → 故意填非法值（如把 int 列填字母）→ 回车 → 条上应附红字错误；cell 应有红框

---

### Task 11: 行内编辑 cell 的右键菜单"设为 NULL" / "取消 NULL"

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`ResultRowView.editingCell(col:)` 内，给 TextField/NULL 显示加 contextMenu)

- [ ] **Step 1: 改 `editingCell(col:)` 加 `.contextMenu`**

定位 Task 7 新增的 `editingCell(col: Int) -> some View` 方法。在末尾 `.background(...)` 那行**之前**追加 `.contextMenu { ... }`：

```swift
        .background(
            RoundedRectangle(cornerRadius: 2)
                .stroke(editHasError ? Color.red : Color.accentColor, lineWidth: 1)
        )
        .contextMenu { editingCellContextMenu(col: col) }
    }
```

注意：上面那个 `}` 是 `editingCell` 函数的关闭。结构：

```swift
@ViewBuilder
private func editingCell(col: Int) -> some View {
    let isNull: Bool = { ... }()
    HStack(spacing: 4) { ... }
        .background(...)
        .contextMenu { editingCellContextMenu(col: col) }
}
```

- [ ] **Step 2: 新增 `editingCellContextMenu` 方法**

在 `editingCell(col:)` 方法下方新增：

```swift
    @ViewBuilder
    private func editingCellContextMenu(col: Int) -> some View {
        let columnName = columns[safe: col] ?? ""
        let def = editColumnDefs.first { $0.name == columnName }
        let nullable = def?.nullable ?? false
        let isNull: Bool = { if case .null = editingDraft { return true } else { return false } }()
        if nullable {
            if isNull {
                Button("取消 NULL（输入值）") { onClearNull() }
            } else {
                Button("设为 NULL") { onSetNull() }
            }
        }
        Button("取消编辑") { onCancelEdit() }
    }
```

> `columns[safe:]` 用现有 `ArraySafeSubscript` 提供的 `subscript(safe:)`。

- [ ] **Step 3: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 手动验证**

Run App：

1. 双击 nullable cell → 右键 → 应见 "设为 NULL" / "取消编辑" 两项
2. 双击 NOT NULL cell（如 id 主键被守门挡了；找其他 NOT NULL 列）→ 右键 → 仅 "取消编辑"，无 "设为 NULL"
3. 点 "设为 NULL" → cell 显 NULL 灰字 → 回车 → SQL 应发 `UPDATE ... SET col = NULL WHERE pk = ...`
4. 进入 NULL 态后再右键 → 应见 "取消 NULL（输入值）" → 点 → cell 变成空 TextField

---

### Task 12: Tab / Shift+Tab 跨列

**Files:**
- Modify: `SSHKeeper/Features/Database/ResultGrid.swift` (`ResultRowView.editingCell(col:)` 的 TextField 加 `.onKeyPress`)

- [ ] **Step 1: 给 TextField 加 `.onKeyPress(.tab)`**

定位 Task 7 新增的 TextField。在 `.onChange(of: editFocus) { ... }` 之后追加：

```swift
                .onChange(of: editFocus) { _, focused in
                    if !focused { onCommit() }
                }
                .onKeyPress(keys: [.tab]) { keyPress in
                    let forward = !keyPress.modifiers.contains(.shift)
                    onTabNav(forward)
                    return .handled
                }
```

> `.onKeyPress(keys:action:)` 在 macOS 14 / SwiftUI 5 可用。`keyPress.modifiers` 类型是 `EventModifiers`，`.shift` 是 case。

- [ ] **Step 2: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`。**若失败**（API 不可用或签名不一致），降级方案：删除 `.onKeyPress` 块，spec 里这条降级（Tab 仅提交不跳列）。回报编译错误后我再决定。

- [ ] **Step 3: 手动验证**

Run App：

1. 双击非主键 cell（如第 2 列）→ 不改值 → Tab → 应直接跳到第 3 列（若可编辑）并进入编辑态
2. 改值 → Tab → 应发 SQL 后跳下一列
3. Shift+Tab → 跳上一列
4. 在最后一可编辑列 Tab → 提交 + 退出编辑态（不跨行）
5. 改值后填非法 → Tab → 应失败留在当前 cell + 红框 + banner 显错（不跳下一列）

---

### Task 13: 删除 `CellViewerSheet.swift`

**Files:**
- Delete: `SSHKeeper/Features/Database/CellViewerSheet.swift`

- [ ] **Step 1: 删除文件**

Run:
```bash
rm ./SSHKeeper/Features/Database/CellViewerSheet.swift
```

- [ ] **Step 2: 重新生成 Xcode 工程**

```bash
cd . && xcodegen generate >/dev/null
```

> xcodegen 按目录 glob 收集 sources，删文件后必须重生成项目才不再编译该文件。

- [ ] **Step 3: 验证无残留引用**

```bash
grep -rn "CellViewerSheet\|CellPresentation" ./SSHKeeper ./SSHKeeperCore ./SSHKeeperTests 2>/dev/null
```

Expected: 无输出（无任何残留引用）。

- [ ] **Step 4: 验证编译**

Run Build.

Expected: `** BUILD SUCCEEDED **`

---

### Task 14: 全量手动验证清单

**Files:** 无新改动。

- [ ] **Step 1: 用户在 Xcode Run，按 spec 第 12 节清单逐条验证**

按 `docs/superpowers/specs/2026-05-20-inline-cell-editing-design.md` 第 12 节 12 项主用例 + 3 项回归用例：

主用例：
1. 双击非主键 cell → TextField 出现、焦点在内
2. 改值回车 → SQL 发出、cell 还原 Text 显示新值
3. 改值后 Esc → cell 还原 Text 显示原值，没有 SQL
4. 不改值回车 → 直接退出，没有 SQL
5. 双击主键列 → 无反应
6. 双击 + 失焦（鼠标点别行 cell）→ 走提交
7. 改值 → 服务端 reject → cell 红框 + 顶部 banner，Esc 可放弃
8. 右键 "设为 NULL" → cell 显 NULL 灰字 → 回车 → 发 UPDATE col = NULL
9. Tab → 同行下一可编辑列；最后一列 → 退出
10. Shift+Tab → 同行上一可编辑列；第一列 → 退出
11. `editConfig == nil`（多表 join / 无主键的查询结果窗口）→ 双击无反应
12. 草稿插入新行 + 同时双击既有行 cell：两者状态独立、Esc 优先取消编辑

回归：
- A. 已有的 `DraftRowView`（插入新行）不受影响
- B. 行级 `selectedRowIdx`、⌘C/⌘V、右键复制行 等不受影响
- C. 排序、列宽拖拽、CSV/TSV 导出不受影响

任一项失败 → 记下症状，告诉我，我评估是修这个 Task 还是开一个独立 follow-up Task。

全部通过 → 行内编辑功能完成。
