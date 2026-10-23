package main

import clay "../vendor/clay/bindings/odin/clay-odin"
import "core:fmt"
import rl "sdlrl"

@(private)
whip_divider: int = -1
@(private)
whip_drag_tab: u32
@(private)
whip_drag_ratio: f32

@(private)
whip_pane_tree :: proc() {
	nodes, root, zoom := rl.WhipTree()
	panes := rl.WhipPanes()
	if root < 0 || root >= len(nodes) {return}
	if zoom != 0 {
		for pane in panes {if pane.id == zoom {whip_pane_slot(pane); return}}
	}
	whip_node(nodes, root, panes)
}

@(private)
whip_node :: proc(nodes: []rl.Whip_Node, index: int, panes: []rl.Whip_Pane) {
	if index < 0 || index >= len(nodes) {return}
	node := nodes[index]
	if node.kind == .Leaf {
		if node.slot < len(panes) {whip_pane_slot(panes[node.slot])}
		return
	}
	if node.kind != .Split {return}
	horizontal := node.axis == .Right
	if clay.UI(clay.ID("WhipSplit", u32(index)))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = horizontal ? .LeftToRight : .TopToBottom,
		},
	},
	) {
		box := clay.GetElementData(clay.ID("WhipSplit", u32(index))).boundingBox
		ratio := index == whip_divider ? whip_drag_ratio : node.ratio
		first := horizontal ? box.width : box.height
		first = max(first - 6, 0) * clamp(ratio, 0.05, 0.95)
		if clay.UI(clay.ID("WhipSplitFirst", u32(index)))(
		{
			layout = {
				sizing = {
					width = horizontal ? clay.SizingFixed(first) : clay.SizingGrow(),
					height = horizontal ? clay.SizingGrow() : clay.SizingFixed(first),
				},
			},
		},
		) {whip_node(nodes, node.first, panes)}
		if clay.UI(clay.ID("WhipDivider", u32(index)))(
		{
			layout = {
				sizing = {
					width = horizontal ? clay.SizingFixed(6) : clay.SizingGrow(),
					height = horizontal ? clay.SizingGrow() : clay.SizingFixed(6),
				},
			},
			backgroundColor = index == whip_divider || hovered() ? ACCENT : DIVIDER,
		},
		) {if hovered() {cursor_raise(.Grabbing)}}
		if clay.UI(clay.ID("WhipSplitSecond", u32(index)))(
		{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
		) {whip_node(nodes, node.second, panes)}
	}
}

@(private)
whip_pane_slot :: proc(pane: rl.Whip_Pane) {
	payload := new(Whip_Payload, context.temp_allocator)
	payload^ = {.Whip, pane.id}
	if clay.UI(clay.ID("WhipPane", pane.id))(
	{
		layout = {
			sizing = {clay.SizingPercent(1), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
		},
		border = {color = pane.focused ? ACCENT : DIVIDER, width = clay.BorderOutside(1)},
		clip = {horizontal = true, vertical = true},
	},
	) {
		if clay.UI(clay.ID("WhipPaneHead", pane.id))(
		{
			layout = {
				sizing = {width = clay.SizingPercent(1), height = clay.SizingFixed(30)},
				childGap = 8,
				padding = {left = 8, right = 4},
				childAlignment = {y = .Center},
			},
			backgroundColor = pane.focused ? SELECTED : PANEL,
		},
		) {
			if clay.UI(clay.ID("WhipPaneTitle", pane.id))(
			{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
			) {clay.Text(pane.name, {fontId = FONT_TITLE, fontSize = 12, textColor = pane.focused ? ACCENT : TEXT_DIM, wrapMode = .None})}
			if pane.mode !=
			   "" {clay.Text(pane.mode, {fontId = FONT_BODY, fontSize = 10, textColor = ACCENT})}
			whip_pane_button("WhipSplitRight", pane.id, "│", tr("Split right"))
			whip_pane_button("WhipSplitDown", pane.id, "─", tr("Split down"))
			whip_pane_button("WhipPaneZoom", pane.id, "□", tr("Maximize or restore pane"))
			whip_pane_button("WhipPaneClose", pane.id, "×", tr("Close pane"))
		}
		if pane.loading {
			clay.Text(
				tr("Opening Whip…"),
				{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
			)
			clay.Text(
				tr("Progress is indeterminate."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
			)
			busy_bar(fmt.tprintf("WhipPaneLoad%d", pane.id))
		}
		if clay.UI(clay.ID("WhipPaneContent", pane.id))(
		{
			layout = {sizing = {clay.SizingPercent(1), clay.SizingGrow()}},
			clip = {horizontal = true, vertical = true},
			custom = {customData = payload},
		},
		) {}
	}
}

@(private)
whip_pane_button :: proc(label: string, pane: u32, symbol, tip: string) {
	if clay.UI(clay.ID(label, pane))(
	{
		layout = {
			sizing = {width = clay.SizingFixed(22), height = clay.SizingFixed(24)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = hovered() ? HOVER : {},
		cornerRadius = rr(4),
	},
	) {
		clay.Text(symbol, {fontId = FONT_BODY, fontSize = 15, textColor = TEXT_DIM})
		if hovered() {cursor_raise(.Pointer); tooltip(tip)}
	}
}

@(private)
whip_pane_input :: proc(ui: ^Ui_State) {
	if ui.page != .Whip || modal_open(ui) {whip_divider = -1; return}
	nodes, _, _ := rl.WhipTree()
	if whip_drag_tab != ui.whip_tabs[ui.whip_project] {whip_divider = -1}
	if rl.IsMouseButtonPressed(.LEFT) {
		for node, i in nodes {
			if node.kind == .Split && clay.PointerOver(clay.ID("WhipDivider", u32(i))) {
				whip_divider, whip_drag_ratio = i, node.ratio
				whip_drag_tab = ui.whip_tabs[ui.whip_project]
				break
			}
		}
	}
	if whip_divider >= 0 && whip_divider < len(nodes) {
		box := clay.GetElementData(clay.ID("WhipSplit", u32(whip_divider))).boundingBox
		point := rl.GetMousePosition()
		point.x /= UI_ZOOM; point.y /= UI_ZOOM
		node := nodes[whip_divider]
		span := node.axis == .Right ? box.width : box.height
		if span > 6 {
			next := node.axis == .Right ? point.x - box.x : point.y - box.y
			next = clamp(next / (span - 6), 0.05, 0.95)
			if abs(next - whip_drag_ratio) >
			   0.001 {whip_drag_ratio = next; rl.WhipPaneRatio(whip_divider, next)}
		}
		if !rl.IsMouseButtonDown(.LEFT) {whip_divider = -1}
		return
	}
	if !mouse_released() {return}
	for pane in rl.WhipPanes() {
		actions := [?]struct {
			id:     string,
			action: rl.Whip_Pane_Action,
		} {
			{"WhipSplitRight", .Split_Right},
			{"WhipSplitDown", .Split_Down},
			{"WhipPaneZoom", .Zoom},
			{"WhipPaneClose", .Close},
		}
		for action in actions {
			if clay.PointerOver(
				clay.ID(action.id, pane.id),
			) {rl.WhipPaneAct(action.action, pane.id); return}
		}
		if clay.PointerOver(
			clay.ID("WhipPaneHead", pane.id),
		) {rl.WhipPaneAct(.Focus, pane.id); return}
	}
}
