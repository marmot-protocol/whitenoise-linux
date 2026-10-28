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
WHIP_GUTTER :: f32(4)

@(private)
WHIP_HEADER_H :: f32(28)
@(private)
WHIP_REVEAL_H :: f32(6)

@(private)
whip_header_open :: proc(root, header: clay.ElementId) -> bool {
	if tap_size() {return true}
	if clay.PointerOver(header) {return true}
	if !clay.PointerOver(root) {return false}
	box := clay.GetElementData(root).boundingBox
	y := clay.GetPointerState().position.y
	return y >= box.y && y < box.y + WHIP_REVEAL_H
}

@(private)
whip_pane_tree :: proc(ui: ^Ui_State) {
	nodes, root, zoom := rl.WhipTree()
	panes := rl.WhipPanes()
	if root < 0 || root >= len(nodes) {return}
	detached: map[u32]bool
	if len(ui.whip_attachments) > 0 {
		detached = make(map[u32]bool, len(ui.whip_attachments), context.temp_allocator)
		for item in ui.whip_attachments {detached[item.pane] = true}
	}
	visible := make([]bool, len(nodes), context.temp_allocator)
	whip_node_visibility(nodes, root, panes, detached, visible)
	if !visible[root] {
		if clay.UI(clay.ID("WhipDetachedNotice"))(
		{layout = {layoutDirection = .TopToBottom, childGap = 4}},
		) {
			clay.Text(
				tr("Panes are floating or docked to chats."),
				{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_DIM},
			)
			for pane in panes {if detached[pane.id] {whip_attach_button("WhipDetachedReturn", pane.id, tr("Return to project"))}}
		}
		return
	}
	if zoom != 0 {
		for pane, i in panes {if pane.id == zoom && !detached[pane.id] {whip_pane_slot(pane, i, zoom); return}}
	}
	if single_pane() {
		if clay.UI(clay.ID("WhipMobilePanes"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				childGap = 8,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		},
		) {
			for pane, i in panes {
				if detached[pane.id] {continue}
				if clay.UI(clay.ID("WhipMobilePane", pane.id))(
				{
					layout = {
						sizing = {
							clay.SizingGrow(),
							clay.SizingFixed(max(180, f32(rl.GetScreenHeight()) / UI_ZOOM - 240)),
						},
					},
				},
				) {
					whip_pane_slot(pane, i)
				}
			}
		}
		scrollbar(clay.ID("WhipMobilePanes"))
		return
	}
	whip_node(nodes, root, panes, visible)
}

@(private)
whip_node_visibility :: proc(
	nodes: []rl.Whip_Node,
	index: int,
	panes: []rl.Whip_Pane,
	detached: map[u32]bool,
	visible: []bool,
) -> bool {
	if index < 0 || index >= len(nodes) {return false}
	node := nodes[index]
	if node.kind == .Leaf {
		visible[index] = node.slot >= 0 && node.slot < len(panes) && !detached[panes[node.slot].id]
	} else if node.kind == .Split {
		first := whip_node_visibility(nodes, node.first, panes, detached, visible)
		second := whip_node_visibility(nodes, node.second, panes, detached, visible)
		visible[index] = first || second
	}
	return visible[index]
}

@(private)
whip_node :: proc(nodes: []rl.Whip_Node, index: int, panes: []rl.Whip_Pane, visible: []bool) {
	if index < 0 || index >= len(nodes) || !visible[index] {return}
	node := nodes[index]
	if node.kind == .Leaf {
		whip_pane_slot(panes[node.slot], node.slot)
		return
	}
	if node.kind != .Split {return}
	first_visible := node.first >= 0 && node.first < len(visible) && visible[node.first]
	second_visible := node.second >= 0 && node.second < len(visible) && visible[node.second]
	if !first_visible {whip_node(nodes, node.second, panes, visible); return}
	if !second_visible {whip_node(nodes, node.first, panes, visible); return}
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
		first = max(first - WHIP_GUTTER, 0) * clamp(ratio, 0.05, 0.95)
		if clay.UI(clay.ID("WhipSplitFirst", u32(index)))(
		{
			layout = {
				sizing = {
					width = horizontal ? clay.SizingFixed(first) : clay.SizingGrow(),
					height = horizontal ? clay.SizingGrow() : clay.SizingFixed(first),
				},
			},
		},
		) {whip_node(nodes, node.first, panes, visible)}
		if clay.UI(clay.ID("WhipDivider", u32(index)))(
		{
			layout = {
				sizing = {
					width = horizontal ? clay.SizingFixed(WHIP_GUTTER) : clay.SizingGrow(),
					height = horizontal ? clay.SizingGrow() : clay.SizingFixed(WHIP_GUTTER),
				},
				childAlignment = {x = .Center, y = .Center},
			},
		},
		) {
			active := index == whip_divider || hovered()
			if active {cursor_raise(horizontal ? .ResizeEW : .ResizeNS)}
			if clay.UI(clay.ID("WhipDividerGrip", u32(index)))(
			{
				layout = {
					sizing = {
						clay.SizingFixed(horizontal ? 2 : 28),
						clay.SizingFixed(horizontal ? 28 : 2),
					},
				},
				backgroundColor = active ? ACCENT : FIELD_BORDER,
				cornerRadius = rr(2),
			},
			) {}
		}
		if clay.UI(clay.ID("WhipSplitSecond", u32(index)))(
		{layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
		) {whip_node(nodes, node.second, panes, visible)}
	}
}

@(private)
whip_pane_slot :: proc(pane: rl.Whip_Pane, index: int, zoom: u32 = 0) {
	root := clay.ID("WhipPane", pane.id)
	show_header := whip_header_open(root, clay.ID("WhipPaneHead", pane.id))
	payload := new(Whip_Payload, context.temp_allocator)
	payload^ = {.Whip, pane.id, show_header ? (tap_size() ? 44 : WHIP_HEADER_H) : WHIP_REVEAL_H}
	if clay.UI(root)(
	{
		layout = {
			sizing = {clay.SizingPercent(1), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(1),
		},
		backgroundColor = PANEL,
		border = {color = pane.focused ? ACCENT_DIM : FIELD_BORDER, width = clay.BorderOutside(1)},
		cornerRadius = rr(8),
		clip = {horizontal = true, vertical = true},
	},
	) {
		if show_header {
			if clay.UI(clay.ID("WhipPaneHead", pane.id))(
			{
				layout = {
					sizing = {
						width = clay.SizingFixed(
							max(clay.GetElementData(root).boundingBox.width - 2, 0),
						),
						height = clay.SizingFixed(tap_size() ? 44 : WHIP_HEADER_H),
					},
					childGap = 4,
					padding = {left = 6, right = 3},
					childAlignment = {y = .Center},
				},
				floating = {
					attachTo = .Parent,
					clipTo = .AttachedParent,
					zIndex = 7,
					offset = {1, 1},
					attachment = {element = .LeftTop, parent = .LeftTop},
				},
				backgroundColor = pane.focused ? SELECTED : PANEL,
				border = {color = pane.focused ? ACCENT_GLOW : DIVIDER, width = {bottom = 1}},
			},
			) {
				if hovered() {cursor_raise(.Pointer)}
				if clay.UI(clay.ID("WhipPaneNumber", pane.id))(
				{
					layout = {
						sizing = {clay.SizingFixed(16), clay.SizingFixed(16)},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = pane.focused ? ACCENT : PLATE,
					cornerRadius = rr(4),
				},
				) {clay.Text(fmt.tprintf("%d", index + 1), {fontId = FONT_MONO, fontSize = 10, textColor = pane.focused ? ON_ACCENT : TEXT_DIM})}
				if clay.UI(clay.ID("WhipPaneTitle", pane.id))(
				{layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}},
				) {
					clay.Text(
						pane.name,
						{
							fontId = FONT_TITLE,
							fontSize = 11,
							textColor = pane.focused ? TEXT : TEXT_DIM,
							wrapMode = .None,
						},
					)
					if hovered() {tooltip(pane.name)}
				}
				if pane.waiting {
					clay.Text("●", {fontId = FONT_BODY, fontSize = 10, textColor = WARNING})
				}
				whip_attach_button("WhipPaneFloat", pane.id, tr("Float"))
				whip_pane_button("WhipSplitRight", pane.id, .Split_Right, tr("Split right"))
				whip_pane_button("WhipSplitDown", pane.id, .Split_Down, tr("Split down"))
				whip_pane_button(
					"WhipPaneZoom",
					pane.id,
					.Zoom,
					zoom == pane.id ? tr("Restore panes") : tr("Maximize pane"),
					zoom,
				)
				whip_pane_button("WhipPaneClose", pane.id, .Close, tr("Close pane"))
			}
		}
		if clay.UI(clay.ID("WhipPaneContent", pane.id))(
		{
			layout = {sizing = {clay.SizingPercent(1), clay.SizingGrow()}},
			clip = {horizontal = true, vertical = true},
			custom = {customData = payload},
		},
		) {whip_pane_progress(pane)}
	}
}

@(private)
whip_pane_progress :: proc(pane: rl.Whip_Pane) {
	if !pane.loading && !pane.restoring {return}
	if clay.UI(clay.ID("WhipPaneProgress", pane.id))(
	{
		layout = {
			sizing = {clay.SizingFit(), clay.SizingFit()},
			layoutDirection = .TopToBottom,
			childGap = 6,
			padding = clay.PaddingAll(10),
		},
		floating = {
			attachTo = .Parent,
			clipTo = .AttachedParent,
			zIndex = 8,
			pointerCaptureMode = .Passthrough,
			offset = {-8, WHIP_HEADER_H + 8},
			attachment = {element = .RightTop, parent = .RightTop},
		},
		backgroundColor = PANEL,
		cornerRadius = rr(6),
		border = {color = DIVIDER, width = bw()},
	},
	) {
		clay.Text(
			tr(pane.restoring ? N_("Restoring terminal history…") : N_("Opening Whip…")),
			{fontId = FONT_BODY, fontSize = 12, textColor = TEXT_DIM},
		)
		clay.Text(
			tr("Progress is indeterminate."),
			{fontId = FONT_BODY, fontSize = 11, textColor = TEXT_LO},
		)
		busy_bar(fmt.tprintf("WhipPaneLoad%d", pane.id))
	}
}

@(private)
whip_pane_button :: proc(
	label: string,
	pane: u32,
	action: rl.Whip_Pane_Action,
	tip: string,
	zoom: u32 = 0,
) {
	selected := action == .Zoom && zoom == pane
	if clay.UI(clay.ID(label, pane))(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(tap_size() ? 44 : 20),
				height = clay.SizingFixed(tap_size() ? 44 : 20),
			},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = hovered() ? (action == .Close ? DANGER_SOFT : HOVER) : (selected ? ACCENT_GLOW : {}),
		cornerRadius = rr(4),
	},
	) {
		color := hovered() ? (action == .Close ? DANGER : TEXT) : (selected ? ACCENT : TEXT_DIM)
		if action == .Close {
			clay.Text("×", {fontId = FONT_BODY, fontSize = 14, textColor = color})
		} else if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingFixed(12), clay.SizingFixed(10)},
				layoutDirection = action == .Split_Down ? .TopToBottom : .LeftToRight,
				padding = clay.PaddingAll(2),
				childGap = 2,
			},
			border = {color = color, width = clay.BorderOutside(1)},
			cornerRadius = rr(2),
		},
		) {
			if action == .Split_Right || action == .Split_Down {
				if clay.UI()(
				{
					layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
					backgroundColor = color,
				},
				) {}
				if clay.UI()(
				{
					layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
					backgroundColor = color,
				},
				) {}
			} else if selected {
				if clay.UI()(
				{
					layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
					border = {color = color, width = clay.BorderOutside(1)},
				},
				) {}
			}
		}
		if hovered() {cursor_raise(.Pointer); tooltip(tip)}
	}
}

@(private)
whip_pane_input :: proc(ui: ^Ui_State) {
	if ui.page != .Chats ||
	   !ui.whip_open ||
	   ui.new_chat_open ||
	   modal_open(ui) {whip_divider = -1; return}
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
		if span > WHIP_GUTTER {
			next := node.axis == .Right ? point.x - box.x : point.y - box.y
			next = clamp(next / (span - WHIP_GUTTER), 0.05, 0.95)
			if abs(next - whip_drag_ratio) >
			   0.001 {whip_drag_ratio = next; rl.WhipPaneRatio(whip_divider, next)}
		}
		if !rl.IsMouseButtonDown(.LEFT) {whip_divider = -1}
		return
	}
	if !mouse_released() {return}
	for pane in rl.WhipPanes() {
		if clay.PointerOver(
			clay.ID("WhipDetachedReturn", pane.id),
		) {whip_attach_rejoin(ui, pane.id); return}
		if whip_attach_index(ui, pane.id) >= 0 {continue}
		if clay.PointerOver(
			clay.ID("WhipPaneFloat", pane.id),
		) {whip_attach_float(ui, pane.id); return}
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
