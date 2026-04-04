extends Control

@export var _canvas: InfiniteCanvas
@export var _statusbar: Statusbar
@export var _topbar: VBoxContainer
@export var _menubar: Menubar
@export var _toolbar: Toolbar
@export var _file_dialog: FileDialog
@export var _export_dialog: FileDialog
@export var _about_window: Window
@export var _settings_window: Window
@export var _settings_dialog: SettingsDialog
@export var _brush_color_picker: ColorPalettePicker
@export var _main_menu: MainMenu
@export var _unsaved_changes_window: Window
@export var _new_palette_window: Window
@export var _delete_palette_window: Window
@export var _edit_palette_window: Window

var _last_input_time := 0
var _ui_visible := true
var _exit_requested := false
var _dirty_project_to_close: Project = null
var _player_enabled := false

signal file_dialog_finished

func _ready() -> void:
	# Init stuff
	Engine.max_fps = Settings.get_value(Settings.RENDERING_FOREGROUND_FPS, Config.DEFAULT_FOREGROUND_FPS)
	get_window().title = "Etch v%s" % Config.VERSION_STRING
	get_tree().auto_accept_quit = false

	var docs_folder := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	_file_dialog.current_dir = Settings.get_value(Settings.GENERAL_DEFAULT_PROJECT_DIR, docs_folder)
	_export_dialog.current_dir = Settings.get_value(Settings.GENERAL_DEFAULT_PROJECT_DIR, docs_folder)

	# Set tablet driver
	var driver: String = Settings.get_value(Settings.GENERAL_TABLET_DRIVER, DisplayServer.tablet_get_current_driver())
	DisplayServer.tablet_set_current_driver(driver)

	# Signals
	get_window().files_dropped.connect(_on_files_dropped)
	Settings.changed_theme.connect(_on_theme_changed)

	# Initialize scale
	_on_scale_changed()

	# Create the default project
	_create_active_default_project()

	# Open project passed as CLI argument
	for arg: String in OS.get_cmdline_args():
		if Utils.is_valid_etch_file(arg):
			_on_open_project(arg)

	# Apply state from previous session
	_apply_state()

	# Set theme
	var themeIndex: int = Settings.get_value(Settings.APPEARANCE_THEME, Config.DEFAULT_APPEARANCE_THEME)
	var themeName : String = Types.UIThemeArray[themeIndex]
	Settings.changed_theme.emit(themeName)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			_on_quit()
		NOTIFICATION_APPLICATION_FOCUS_IN:
			Engine.max_fps = Settings.get_value(Settings.RENDERING_FOREGROUND_FPS, Config.DEFAULT_FOREGROUND_FPS)
			if _canvas and not (_is_mouse_on_ui() or is_dialog_open()):
				await get_tree().create_timer(0.12).timeout
				_canvas.enable()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			Engine.max_fps = Settings.get_value(Settings.RENDERING_BACKGROUND_FPS, Config.DEFAULT_BACKGROUND_FPS)
			if _canvas:
				_canvas.disable()


func _exit_tree() -> void:
	_menubar.remove_all_tabs()
	ProjectManager.remove_all_projects()


func _process(delta: float) -> void:
	# Lower FPS if user is idle
	var idle := (Time.get_ticks_msec() - _last_input_time) > Config.BACKGROUND_IDLE_TIME_THRESHOLD
	if idle and not(_player_enabled or _canvas.is_drawing()):
		Engine.max_fps = Settings.get_value(Settings.RENDERING_BACKGROUND_FPS, Config.DEFAULT_BACKGROUND_FPS)

	# Upate statusbar
	_statusbar.set_stroke_count(_canvas.info.stroke_count)
	_statusbar.set_point_count(_canvas.info.point_count)
	_statusbar.set_pressure(_canvas.info.current_pressure)
	_statusbar.set_camera_position(_canvas.get_camera_offset())
	_statusbar.set_camera_zoom(_canvas.get_camera_zoom())
	_statusbar.set_fps(Engine.get_frames_per_second())

	# Update tab title
	var active_project: Project = ProjectManager.get_active_project()
	if active_project:
		_menubar.update_tab_title(active_project)


func _unhandled_input(event: InputEvent) -> void:
	# Reset FPS
	_last_input_time = Time.get_ticks_msec()
	Engine.max_fps = Settings.get_value(Settings.RENDERING_FOREGROUND_FPS, Config.DEFAULT_FOREGROUND_FPS)

	if not is_dialog_open():
		if Utils.is_action_pressed("toggle_player", event):
			_toggle_player()

		if not _player_enabled:
			if Utils.is_action_pressed("shortcut_new_project", event):
				_on_create_new_project()
			elif Utils.is_action_pressed("shortcut_open_project", event):
				_toolbar._on_open_project_pressed()
			elif Utils.is_action_pressed("shortcut_save_project", event):
				_on_save_project()
			elif Utils.is_action_pressed("shortcut_close_project", event):
				if ProjectManager.get_project_count() > 0:
					_on_project_closed(ProjectManager.get_active_project().id)
			elif Utils.is_action_pressed("shortcut_export_project", event):
				_export_svg()
			elif Utils.is_action_pressed("shortcut_quit", event):
				_on_quit()
			elif Utils.is_action_pressed("shortcut_undo", event):
				_on_undo_action()
			elif Utils.is_action_pressed("shortcut_redo", event):
				_on_redo_action()
			elif Utils.is_action_pressed("shortcut_brush_tool", event):
				_toolbar.enable_tool(Types.Tool.BRUSH)
			elif Utils.is_action_pressed("shortcut_rectangle_tool", event):
				_toolbar.enable_tool(Types.Tool.RECTANGLE)
			elif Utils.is_action_pressed("shortcut_circle_tool", event):
				_toolbar.enable_tool(Types.Tool.CIRCLE)
			elif Utils.is_action_pressed("shortcut_line_tool", event):
				_toolbar.enable_tool(Types.Tool.LINE)
			elif Utils.is_action_pressed("shortcut_eraser_tool", event):
				_toolbar.enable_tool(Types.Tool.ERASER)
			elif Utils.is_action_pressed("shortcut_select_tool", event):
				_toolbar.enable_tool(Types.Tool.SELECT)
			elif Utils.is_action_pressed("toggle_zen_mode", event):
				_toggle_zen_mode()
			elif Utils.is_action_pressed("toggle_fullscreen", event):
				_toggle_fullscreen()


func _toggle_player() -> void:
	_player_enabled = not _player_enabled
	_canvas.enable_player(_player_enabled)


func _save_state() -> void:
	# Open projects
	var open_projects: Array[String]
	for project: Project in ProjectManager.get_open_projects():
		open_projects.append(project.filepath)
	StatePersistence.set_value(StatePersistence.OPEN_PROJECTS, open_projects)

	# Active project
	var active_project_path := ProjectManager.get_active_project().filepath
	StatePersistence.set_value(StatePersistence.ACTIVE_PROJECT, active_project_path)

	# Window related stuff
	StatePersistence.set_value(StatePersistence.WINDOW_SCREEN, get_window().current_screen)
	StatePersistence.set_value(StatePersistence.WINDOW_SIZE, get_window().size)
	StatePersistence.set_value(StatePersistence.WINDOW_MAXIMIZED, (get_window().mode == Window.MODE_MAXIMIZED))
	StatePersistence.set_value(StatePersistence.WINDOW_POS, get_window().position)


func _apply_state() -> void:
	# Window related stuff
	var is_maximized: bool = StatePersistence.get_value(StatePersistence.WINDOW_MAXIMIZED, false)
	var default_win_size := Vector2(1440, 810)
	var win_size: Vector2 = StatePersistence.get_value(StatePersistence.WINDOW_SIZE, default_win_size)
	var screen: int = StatePersistence.get_value(StatePersistence.WINDOW_SCREEN, DisplayServer.SCREEN_PRIMARY)
	var win_pos: Vector2 = StatePersistence.get_value(StatePersistence.WINDOW_POS, DisplayServer.screen_get_usable_rect(screen).get_center())

	if is_maximized:
		get_window().mode = Window.MODE_MAXIMIZED
	else:
		get_window().set_current_screen(screen)
		get_window().size = win_size
		get_window().position = win_pos
	await get_tree().process_frame

	# Open projects
	var open_projects: Array = StatePersistence.get_value(StatePersistence.OPEN_PROJECTS, Array())
	for path: String in open_projects:
		_on_open_project(path)

	# Active project
	var active_project_path: String = StatePersistence.get_value(StatePersistence.ACTIVE_PROJECT, "")
	var active_project := ProjectManager.get_open_project_by_filepath(active_project_path)
	if active_project:
		_make_project_active(active_project)


func _on_quit() -> void:
	if ProjectManager.has_unsaved_changes():
		_exit_requested = true
		_unsaved_changes_window.popup_centered()
	else:
		_save_state()
		get_tree().quit()


func _toggle_zen_mode() -> void:
	_ui_visible = not _ui_visible
	_topbar.visible = _ui_visible
	_statusbar.visible = _ui_visible


func _on_files_dropped(files: PackedStringArray) -> void:
	for file: String in files:
		if Utils.is_valid_etch_file(file):
			_on_open_project(file)


func _make_project_active(project: Project) -> void:
	ProjectManager.make_project_active(project)
	_canvas.use_project(project)

	if not _menubar.has_tab(project):
		_menubar.make_tab(project)
	_menubar.set_tab_active(project)


func _is_mouse_on_ui() -> bool:
	var on_ui := (
		Utils.is_mouse_in_control(_menubar)
		or Utils.is_mouse_in_control(_toolbar)
		or Utils.is_mouse_in_control(_statusbar)
		or Utils.is_mouse_on_window(_file_dialog)
		or Utils.is_mouse_on_window(_about_window)
		or Utils.is_mouse_on_window(_settings_window)
		or Utils.is_mouse_in_control(_brush_color_picker)
		or Utils.is_mouse_on_window(_new_palette_window)
		or Utils.is_mouse_on_window(_edit_palette_window)
		or Utils.is_mouse_on_window(_delete_palette_window)
	)
	return on_ui


func is_dialog_open() -> bool:
	return (
		_about_window.visible
		or _settings_window.visible
		or _new_palette_window.visible
		or _edit_palette_window.visible
		or _delete_palette_window.visible
		or _file_dialog.visible
		or _unsaved_changes_window.visible
		or AlertDialog.visible
	)


func _create_active_default_project() -> void:
	var default_project: Project = ProjectManager.add_project()
	_make_project_active(default_project)


func _save_project(project: Project) -> void:
	var meta_data := ProjectMetadata.make_dict(_canvas)
	project.meta_data = meta_data
	ProjectManager.save_project(project)
	_menubar.update_tab_title(project)


func _on_create_new_project() -> void:
	_create_active_default_project()


func _on_project_selected(project_id: int) -> void:
	var project: Project = ProjectManager.get_project_by_id(project_id)
	_make_project_active(project)


func _on_project_closed(project_id: int) -> void:
	# Ask the user to save changes
	var project: Project = ProjectManager.get_project_by_id(project_id)
	if project.dirty:
		_dirty_project_to_close = project
		_unsaved_changes_window.popup_centered()
	else:
		_close_project(project_id)


func _close_project(project_id: int) -> void:
	var active_project: Project = ProjectManager.get_active_project()
	var project: Project = ProjectManager.get_project_by_id(project_id)
	var active_project_closed := active_project.id == project.id

	# Remove project
	ProjectManager.remove_project(project)
	_menubar.remove_tab(project)

	# Choose new project if active tab was closed
	if active_project_closed:
		if not ProjectManager.get_project_count():
			_create_active_default_project()
		else:
			var new_project_id: int = _menubar.get_first_project_id()
			var new_project: Project = ProjectManager.get_project_by_id(new_project_id)
			_make_project_active(new_project)


func _toggle_fullscreen() -> void:
	if get_window().mode in [Window.MODE_EXCLUSIVE_FULLSCREEN, Window.MODE_FULLSCREEN]:
		get_window().mode = Window.MODE_WINDOWED
	else:
		get_window().mode = Window.MODE_FULLSCREEN


func _on_brush_color_changed(brush_color: Color) -> void:
	_canvas.set_brush_color(brush_color)


func _on_brush_size_changed(brush_size: int) -> void:
	_canvas.set_brush_size(brush_size)


func _on_grid_size_changed(grid_size: int) -> void:
	_canvas.grid.set_grid_size(grid_size)


func _on_grid_pattern_changed(pattern: int) -> void:
	_canvas.grid.set_grid_pattern(pattern)


func _on_canvas_color_changed(canvas_color: Color) -> void:
	_canvas.set_background_color(canvas_color)
	_canvas.grid.set_canvas_color(canvas_color)


func _on_clear_canvas() -> void:
	_canvas.clear()


func _on_open_project(filepath: String) -> bool:
	# Check if file exists
	if not FileAccess.file_exists(filepath):
		return false

	var project: Project = ProjectManager.get_open_project_by_filepath(filepath)
	var active_project: Project = ProjectManager.get_active_project()

	# Project already open. Just switch to tab
	if project:
		if project != active_project:
			_make_project_active(project)
		return true

	# Remove/Replace active project if not changed and unsaved (default project)
	if active_project.filepath.is_empty() and not active_project.dirty:
		ProjectManager.remove_project(active_project)
		_menubar.remove_tab(active_project)

	# Create and open it
	project = ProjectManager.add_project(filepath)
	_make_project_active(project)

	return true


func _on_save_project_as() -> void:
	var active_project: Project = ProjectManager.get_active_project()
	_canvas.disable()
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.current_file = active_project.filepath.get_file()
	_file_dialog.file_selected.connect(_on_file_selected_to_save_project)
	_file_dialog.close_requested.connect(_on_file_dialog_closed)
	_file_dialog.canceled.connect(_on_file_dialog_canceled)
	_file_dialog.popup_centered()
	await file_dialog_finished


func _on_save_project() -> void:
	var active_project: Project = ProjectManager.get_active_project()
	if active_project.filepath.is_empty():
		_on_save_project_as()
	else:
		_save_project(active_project)

func _on_file_dialog_canceled() -> void:
	file_dialog_finished.emit()


func _on_file_dialog_closed() -> void:
	_file_dialog.file_selected.disconnect(_on_file_selected_to_save_project)
	_file_dialog.close_requested.disconnect(_on_file_dialog_closed)
	file_dialog_finished.emit()


func _on_file_selected_to_save_project(filepath: String) -> void:
	var active_project: Project = ProjectManager.get_active_project()
	active_project.filepath = filepath
	_save_project(active_project)
	file_dialog_finished.emit()


func _on_canvas_background_changed(color: Color) -> void:
	_canvas.set_background_color(color)


func _on_undo_action() -> void:
	var project: Project = ProjectManager.get_active_project()
	if project.undo_redo.has_undo():
		project.undo_redo.undo()


func _on_redo_action() -> void:
	var project: Project = ProjectManager.get_active_project()
	if project.undo_redo.has_redo():
		project.undo_redo.redo()


func _on_tool_changed(tool_type: int) -> void:
	_canvas.use_tool(tool_type)


func _on_save_unsaved_changes() -> void:
	if _exit_requested:
		for project in ProjectManager.get_open_projects():
			ProjectManager.make_project_active(project)
			if project.loaded and project.dirty:
				if project.filepath.is_empty():
					await _on_save_project_as()
				else:
					_on_save_project()
		_save_state()
		get_tree().quit()
	elif _dirty_project_to_close:
			ProjectManager.save_project(_dirty_project_to_close)
			_close_project(_dirty_project_to_close.id)
			_dirty_project_to_close = null


func _on_discard_unsaved_changes() -> void:
	if _exit_requested:
		_save_state()
		get_tree().quit()
	elif _dirty_project_to_close:
			_close_project(_dirty_project_to_close.id)
			_dirty_project_to_close = null


func _on_open_about_dialog() -> void:
	_about_window.popup()


func _on_open_settings_dialog() -> void:
	_settings_window.popup()


func _on_open_url(url: String) -> void:
	OS.shell_open(url)
	await get_tree().create_timer(0.1).timeout
	_canvas.disable()


func _on_infinite_canvas_mouse_entered() -> void:
	if not (is_dialog_open() or _is_mouse_on_ui()):
		_canvas.enable()


func _on_infinite_canvas_mouse_exited() -> void:
	_canvas.disable()


func _on_export_confirmed(path: String) -> void:
	match path.get_extension():
		"svg":
			var project: Project = ProjectManager.get_active_project()
			if project:
				var background := _canvas.get_background_color()
				var svg := SvgExporter.new()
				svg.export_svg(project.strokes, background, path)
		_:
			OS.alert("Unsupported format")

	if not (is_dialog_open() or _is_mouse_on_ui()):
		_canvas.enable()


func _export_svg() -> void:
	_export_dialog.filters = ["*.svg ; Scalable Vector graphics"]
	_export_dialog.current_file = "etch.svg"
	_export_dialog.popup()


func _on_toggle_brush_color_picker() -> void:
	_brush_color_picker.toggle()


func _on_brush_color_picker_color_changed(color: Color) -> void:
	_toolbar.set_brush_color(color)
	_canvas.set_brush_color(color)


func _on_brush_color_picker_closed() -> void:
	if not _is_mouse_on_ui():
		_canvas.enable()


func _on_new_palette_dialog_new_palette_created(palette: Palette) -> void:
	PaletteManager.set_active_palette(palette)
	_brush_color_picker.update_palettes()


func _update_brush_color() -> void:
	var color_index: int = min(_brush_color_picker.get_active_color_index(),
		PaletteManager.get_active_palette().colors.size() - 1)
	_brush_color_picker.update_palettes(color_index)
	_toolbar.set_brush_color(_brush_color_picker.get_active_color())
	_canvas.set_brush_color(_brush_color_picker.get_active_color())


func _on_edit_palette_dialog_palette_changed() -> void:
	_update_brush_color()


func _on_delete_palette_dialog_palette_deleted() -> void:
	_update_brush_color()


func _on_scale_changed() -> void:
	var auto_scale: int = Settings.get_value(Settings.APPEARANCE_UI_SCALE_MODE, Config.DEFAULT_UI_SCALE_MODE)
	var new_scale: float
	match auto_scale:
		Types.UIScale.AUTO:
			new_scale = _get_platform_ui_scale()
		Types.UIScale.CUSTOM:
			new_scale = Settings.get_value(Settings.APPEARANCE_UI_SCALE, Config.DEFAULT_UI_SCALE)
	new_scale = clamp(new_scale, _settings_dialog.get_min_ui_scale(), _settings_dialog.get_max_ui_scale())

	# TODO(gd4): the whole scaling stuff changed a lot in Godot 4; need to figure this out later.
	# See: https://www.reddit.com/r/godot/comments/14h4iir/how_can_i_set_the_stretch_mode_and_aspect_in/
	get_tree().root.content_scale_factor = new_scale
	get_window().min_size = Config.MIN_WINDOW_SIZE * new_scale


func _on_constant_pressure_changed(enable: bool) -> void:
	_canvas.enable_constant_pressure(enable)


func _get_platform_ui_scale() -> float:
	var platform: String = OS.get_name()
	match platform:
		"OSX":
			return DisplayServer.screen_get_scale()
		"Windows":
			return DisplayServer.screen_get_dpi() / 96.0
		_:
			return _get_general_ui_scale()


func _get_general_ui_scale() -> float:
	# Adapted from Godot EditorSettings::get_auto_display_scale()
	# https://github.com/godotengine/godot/blob/3.x/editor/editor_settings.cpp
	var smallest_dimension: int = min(DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y)
	if DisplayServer.screen_get_dpi() >= 192 and smallest_dimension >= 1400:
		return Config.DEFAULT_UI_SCALE * 2
	elif smallest_dimension >= 1700:
		return Config.DEFAULT_UI_SCALE * 1.5
	return Config.DEFAULT_UI_SCALE


func _on_theme_changed(path: String) -> void:
	var themePath: String = str("res://UI/Themes/", path, "/theme.tres")
	var toolBarPath: String = str("res://UI/Themes/", path, "/toolbar.tres")
	var new_theme: Theme = load(themePath)
	var toolbarTheme: StyleBoxFlat = load(toolBarPath)
	set_theme(new_theme)
	_toolbar.set_theme(new_theme)
	_toolbar.add_theme_stylebox_override("panel", toolbarTheme)
	_toolbar.queue_redraw()
	_statusbar.set_theme(new_theme)
	_statusbar.queue_redraw()
	_menubar.set_theme(new_theme)
	_menubar.queue_redraw()
	_main_menu.set_theme(new_theme)
	_settings_dialog.set_theme(new_theme)
	_settings_dialog.queue_redraw()
	queue_redraw()


func _on_statusbar_reset_position() -> void:
	_canvas.set_camera_offset(Vector2.ZERO)


func _on_statusbar_reset_zoom() -> void:
	_canvas.set_camera_zoom(1)
