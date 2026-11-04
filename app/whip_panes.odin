package main

import "core:fmt"
import "nendo"
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
whip_header_open :: proc(root, header: nendo.Id) -> bool {
	if tap_size() {return true}
	if nendo.pointer_over(header) {return true}
	if !nendo.pointer_over(root) {return false}
	box := nendo.element(root).rect
	y := nendo.pointer().position.y
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
		if nendo.box(nendo.id("WhipDetachedNotice"))({direction = .Column, gap = 4}) {
			nendo.text(
				tr("Panes are floating or docked to chats."),
				{font = FONT_BODY, size = 11, color = TEXT_DIM},
			)
			for pane in panes {if detached[pane.id] {whip_attach_button("WhipDetachedReturn", pane.id, tr("Return to project"))}}
		}
		return
	}
	if zoom != 0 && !single_pane() {
		for pane, i in panes {if pane.id == zoom && !detached[pane.id] {whip_pane_slot(pane, i, zoom); return}}
	}
	if single_pane() {
		if nendo.box(nendo.id("WhipMobilePanes"))(
		{width = nendo.grow(), height = nendo.grow(), direction = .Column, gap = 4},
		) {
			selected := -1
			for pane, i in panes {
				if detached[pane.id] {continue}
				if selected < 0 || pane.focused {selected = i}
			}
			if len(panes) > 1 {
				if nendo.box(nendo.id("WhipPhoneTabs"))(
				{
					width = nendo.grow(),
					height = nendo.fixed(44),
					gap = 4,
					clip = {x = true, scroll = true},
				},
				) {
					for pane, i in panes {
						if detached[pane.id] {continue}
						if nendo.box(nendo.id("WhipPhonePane", pane.id))(
						{
							width = nendo.fixed(140),
							height = nendo.fixed(44),
							padding = {left = 10, right = 10},
							align = {y = .Center},
							color = i == selected ? SELECTED : ROW_BG,
							radius = rr(6),
							clip = {x = true},
						},
						) {
							nendo.text(
								fmt.tprintf("%d  %s", i + 1, pane.name),
								{
									font = FONT_BODY,
									size = 12,
									color = i == selected ? TEXT : TEXT_DIM,
									wrap = .None,
								},
							)
						}
					}
				}
				scrollbar(nendo.id("WhipPhoneTabs"))
			}
			if selected >= 0 {whip_pane_slot(panes[selected], selected)}
		}
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
	if nendo.box(nendo.id("WhipSplit", u32(index)))(
	{width = nendo.grow(), height = nendo.grow(), direction = horizontal ? .Row : .Column},
	) {
		box := nendo.element(nendo.id("WhipSplit", u32(index))).rect
		ratio := index == whip_divider ? whip_drag_ratio : node.ratio
		first := horizontal ? box.width : box.height
		first = max(first - WHIP_GUTTER, 0) * clamp(ratio, 0.05, 0.95)
		if nendo.box(nendo.id("WhipSplitFirst", u32(index)))(
		{
			width = horizontal ? nendo.fixed(first) : nendo.grow(),
			height = horizontal ? nendo.grow() : nendo.fixed(first),
		},
		) {whip_node(nodes, node.first, panes, visible)}
		if nendo.box(nendo.id("WhipDivider", u32(index)))(
		{
			width = horizontal ? nendo.fixed(WHIP_GUTTER) : nendo.grow(),
			height = horizontal ? nendo.grow() : nendo.fixed(WHIP_GUTTER),
			align = {x = .Center, y = .Center},
		},
		) {
			active := index == whip_divider || hovered()
			if active {cursor_raise(horizontal ? .ResizeEW : .ResizeNS)}
			if nendo.box(nendo.id("WhipDividerGrip", u32(index)))(
			{
				width = nendo.fixed(horizontal ? 2 : 28),
				height = nendo.fixed(horizontal ? 28 : 2),
				color = active ? ACCENT : FIELD_BORDER,
				radius = rr(2),
			},
			) {}
		}
		if nendo.box(nendo.id("WhipSplitSecond", u32(index)))(
		{width = nendo.grow(), height = nendo.grow()},
		) {whip_node(nodes, node.second, panes, visible)}
	}
}

@(private)
whip_pane_slot :: proc(pane: rl.Whip_Pane, index: int, zoom: u32 = 0) {
	root := nendo.id("WhipPane", pane.id)
	show_header := !single_pane() && whip_header_open(root, nendo.id("WhipPaneHead", pane.id))
	payload := new(Whip_Payload, context.temp_allocator)
	payload^ = {
		.Whip,
		pane.id,
		single_pane() ? 0 : (show_header ? (tap_size() ? tap_min() : WHIP_HEADER_H) : WHIP_REVEAL_H),
	}
	if nendo.box(root)(
	{
		width = nendo.percent(1),
		height = nendo.grow(),
		direction = .Column,
		padding = nendo.pad(1),
		color = PANEL,
		border = {color = pane.focused ? ACCENT_DIM : FIELD_BORDER, width = nendo.outline(1)},
		radius = rr(8),
		clip = {x = true, y = true},
	},
	) {
		if show_header {
			if nendo.box(nendo.id("WhipPaneHead", pane.id))(
			{
				width = nendo.fixed(max(nendo.element(root).rect.width - 2, 0)),
				height = nendo.fixed(tap_size() ? tap_min() : WHIP_HEADER_H),
				gap = 4,
				padding = {left = 6, right = 3},
				align = {y = .Center},
				floating = {
					attach_to = .Parent,
					clip_to = .Parent,
					z = 7,
					offset = {1, 1},
					attach = {element = .Left_Top, parent = .Left_Top},
				},
				color = pane.focused ? SELECTED : PANEL,
				border = {color = pane.focused ? ACCENT_GLOW : DIVIDER, width = {bottom = 1}},
			},
			) {
				if hovered() {cursor_raise(.Pointer)}
				if nendo.box(nendo.id("WhipPaneNumber", pane.id))(
				{
					width = nendo.fixed(16),
					height = nendo.fixed(16),
					align = {x = .Center, y = .Center},
					color = pane.focused ? ACCENT : PLATE,
					radius = rr(4),
				},
				) {nendo.text(fmt.tprintf("%d", index + 1), {font = FONT_MONO, size = 10, color = pane.focused ? ON_ACCENT : TEXT_DIM})}
				if nendo.box(nendo.id("WhipPaneTitle", pane.id))(
				{width = nendo.grow(), clip = {x = true}},
				) {
					nendo.text(
						pane.name,
						{
							font = FONT_TITLE,
							size = 11,
							color = pane.focused ? TEXT : TEXT_DIM,
							wrap = .None,
						},
					)
					if hovered() {tooltip(pane.name)}
				}
				if pane.waiting {
					nendo.text("●", {font = FONT_BODY, size = 10, color = WARNING})
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
		if nendo.box(nendo.id("WhipPaneContent", pane.id))(
		{
			width = nendo.percent(1),
			height = nendo.grow(),
			clip = {x = true, y = true},
			custom = payload,
		},
		) {whip_pane_progress(pane)}
	}
}

@(private)
whip_pane_progress :: proc(pane: rl.Whip_Pane) {
	if !pane.loading && !pane.restoring {return}
	if nendo.box(nendo.id("WhipPaneProgress", pane.id))(
	{
		width = nendo.fit(),
		height = nendo.fit(),
		direction = .Column,
		gap = 6,
		padding = nendo.pad(10),
		floating = {
			attach_to = .Parent,
			clip_to = .Parent,
			z = 8,
			pointer = .Passthrough,
			offset = {-8, WHIP_HEADER_H + 8},
			attach = {element = .Right_Top, parent = .Right_Top},
		},
		color = PANEL,
		radius = rr(6),
		border = {color = DIVIDER, width = bw()},
	},
	) {
		nendo.text(
			tr(pane.restoring ? N_("Restoring terminal history…") : N_("Opening Whip…")),
			{font = FONT_BODY, size = 12, color = TEXT_DIM},
		)
		nendo.text(
			tr("Progress is indeterminate."),
			{font = FONT_BODY, size = 11, color = TEXT_LO},
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
	if nendo.box(nendo.id(label, pane))(
	{
		width = nendo.fixed(tap_size() ? tap_min() : 20),
		height = nendo.fixed(tap_size() ? tap_min() : 20),
		align = {x = .Center, y = .Center},
		color = hovered() ? (action == .Close ? DANGER_SOFT : HOVER) : (selected ? ACCENT_GLOW : {}),
		radius = rr(4),
	},
	) {
		color := hovered() ? (action == .Close ? DANGER : TEXT) : (selected ? ACCENT : TEXT_DIM)
		if action == .Close {
			nendo.text("×", {font = FONT_BODY, size = 14, color = color})
		} else if nendo.box()(
		{
			width = nendo.fixed(12),
			height = nendo.fixed(10),
			direction = action == .Split_Down ? .Column : .Row,
			padding = nendo.pad(2),
			gap = 2,
			border = {color = color, width = nendo.outline(1)},
			radius = rr(2),
		},
		) {
			if action == .Split_Right || action == .Split_Down {
				if nendo.box()({width = nendo.grow(), height = nendo.grow(), color = color}) {}
				if nendo.box()({width = nendo.grow(), height = nendo.grow(), color = color}) {}
			} else if selected {
				if nendo.box()(
				{
					width = nendo.grow(),
					height = nendo.grow(),
					border = {color = color, width = nendo.outline(1)},
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
			if node.kind == .Split && nendo.pointer_over(nendo.id("WhipDivider", u32(i))) {
				whip_divider, whip_drag_ratio = i, node.ratio
				whip_drag_tab = ui.whip_tabs[ui.whip_project]
				break
			}
		}
	}
	if whip_divider >= 0 && whip_divider < len(nodes) {
		box := nendo.element(nendo.id("WhipSplit", u32(whip_divider))).rect
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
		if nendo.pointer_over(
			nendo.id("WhipPhonePane", pane.id),
		) {rl.WhipPaneAct(.Focus, pane.id); return}
		if nendo.pointer_over(
			nendo.id("WhipDetachedReturn", pane.id),
		) {whip_attach_rejoin(ui, pane.id); return}
		if whip_attach_index(ui, pane.id) >= 0 {continue}
		if nendo.pointer_over(
			nendo.id("WhipPaneFloat", pane.id),
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
			if nendo.pointer_over(
				nendo.id(action.id, pane.id),
			) {rl.WhipPaneAct(action.action, pane.id); return}
		}
		if nendo.pointer_over(
			nendo.id("WhipPaneHead", pane.id),
		) {rl.WhipPaneAct(.Focus, pane.id); return}
	}
}
