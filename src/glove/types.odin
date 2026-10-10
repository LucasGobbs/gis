package glove

import "base:runtime"

Button_Action :: distinct int
Axis_2D_Action :: distinct int

Key :: enum u16 {
	UNKNOWN = 0,
	A = 4,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	_1,
	_2,
	_3,
	_4,
	_5,
	_6,
	_7,
	_8,
	_9,
	_0,
	RETURN,
	ESCAPE,
	BACKSPACE,
	TAB,
	SPACE,
	MINUS,
	EQUALS,
	LEFTBRACKET,
	RIGHTBRACKET,
	BACKSLASH,
	NONUSHASH,
	SEMICOLON,
	APOSTROPHE,
	GRAVE,
	COMMA,
	PERIOD,
	SLASH,
	CAPSLOCK,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	PRINTSCREEN,
	SCROLLLOCK,
	PAUSE,
	INSERT,
	HOME,
	PAGEUP,
	DELETE,
	END,
	PAGEDOWN,
	RIGHT,
	LEFT,
	DOWN,
	UP,
	NUMLOCKCLEAR,
	KP_DIVIDE,
	KP_MULTIPLY,
	KP_MINUS,
	KP_PLUS,
	KP_ENTER,
	KP_1,
	KP_2,
	KP_3,
	KP_4,
	KP_5,
	KP_6,
	KP_7,
	KP_8,
	KP_9,
	KP_0,
	KP_PERIOD,
	NONUSBACKSLASH,
	APPLICATION,
	POWER,
	KP_EQUALS,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	EXECUTE,
	HELP,
	MENU,
	SELECT,
	STOP,
	AGAIN,
	UNDO,
	CUT,
	COPY,
	PASTE,
	FIND,
	MUTE,
	VOLUMEUP,
	VOLUMEDOWN,
	KP_COMMA = 133,
	KP_EQUALSAS400,
	INTERNATIONAL1,
	INTERNATIONAL2,
	INTERNATIONAL3,
	INTERNATIONAL4,
	INTERNATIONAL5,
	INTERNATIONAL6,
	INTERNATIONAL7,
	INTERNATIONAL8,
	INTERNATIONAL9,
	LANG1,
	LANG2,
	LANG3,
	LANG4,
	LANG5,
	LANG6,
	LANG7,
	LANG8,
	LANG9,
	ALTERASE,
	SYSREQ,
	CANCEL,
	CLEAR,
	PRIOR,
	RETURN2,
	SEPARATOR,
	OUT,
	OPER,
	CLEARAGAIN,
	CRSEL,
	EXSEL,
	KP_00 = 176,
	KP_000,
	THOUSANDSSEPARATOR,
	DECIMALSEPARATOR,
	CURRENCYUNIT,
	CURRENCYSUBUNIT,
	KP_LEFTPAREN,
	KP_RIGHTPAREN,
	KP_LEFTBRACE,
	KP_RIGHTBRACE,
	KP_TAB,
	KP_BACKSPACE,
	KP_A,
	KP_B,
	KP_C,
	KP_D,
	KP_E,
	KP_F,
	KP_XOR,
	KP_POWER,
	KP_PERCENT,
	KP_LESS,
	KP_GREATER,
	KP_AMPERSAND,
	KP_DBLAMPERSAND,
	KP_VERTICALBAR,
	KP_DBLVERTICALBAR,
	KP_COLON,
	KP_HASH,
	KP_SPACE,
	KP_AT,
	KP_EXCLAM,
	KP_MEMSTORE,
	KP_MEMRECALL,
	KP_MEMCLEAR,
	KP_MEMADD,
	KP_MEMSUBTRACT,
	KP_MEMMULTIPLY,
	KP_MEMDIVIDE,
	KP_PLUSMINUS,
	KP_CLEAR,
	KP_CLEARENTRY,
	KP_BINARY,
	KP_OCTAL,
	KP_DECIMAL,
	KP_HEXADECIMAL,
	LCTRL = 224,
	LSHIFT,
	LALT,
	LGUI,
	RCTRL,
	RSHIFT,
	RALT,
	RGUI,
	MODE = 257,
	SLEEP,
	WAKE,
	CHANNEL_INCREMENT,
	CHANNEL_DECREMENT,
	MEDIA_PLAY,
	MEDIA_PAUSE,
	MEDIA_RECORD,
	MEDIA_FAST_FORWARD,
	MEDIA_REWIND,
	MEDIA_NEXT_TRACK,
	MEDIA_PREVIOUS_TRACK,
	MEDIA_STOP,
	MEDIA_EJECT,
	MEDIA_PLAY_PAUSE,
	MEDIA_SELECT,
	AC_NEW,
	AC_OPEN,
	AC_CLOSE,
	AC_EXIT,
	AC_SAVE,
	AC_PRINT,
	AC_PROPERTIES,
	AC_SEARCH,
	AC_HOME,
	AC_BACK,
	AC_FORWARD,
	AC_STOP,
	AC_REFRESH,
	AC_BOOKMARKS,
	SOFTLEFT,
	SOFTRIGHT,
	CALL,
	ENDCALL,
	COUNT = 512,
}


// Keyboard modifiers tracked by the system, derived from the modifier
// keys themselves. Bindings match them exactly, so a chord never fires
// when only its base key is pressed (and vice versa).
Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Gui,
}

Modifiers :: bit_set[Modifier; u8]

KEY_COUNT :: int(Key.COUNT)

Mouse_Button :: enum u8 {
	Unknown,
	Left,
	Middle,
	Right,
	X1,
	X2,
	Count,
}

MOUSE_BUTTON_COUNT :: int(Mouse_Button.Count)

Mouse_State :: struct {
	buttons:  [MOUSE_BUTTON_COUNT]bool,
	position: [2]f32,
	delta:    [2]f32,
	wheel:    [2]f32,
}

Button_State :: struct {
	down:     bool,
	pressed:  bool,
	released: bool,
}

Axis_2D_State :: struct {
	value:    [2]f32,
	previous: [2]f32,
	changed:  bool,
}

Button_Axis_2D_Desc :: struct {
	up:        Key,
	down:      Key,
	left:      Key,
	right:     Key,
	normalize: bool,
}

Button_Action_Data :: struct {
	name:          string,
	state:         Button_State,
	previous_down: bool,
	respects:      Captures,
}

Axis_2D_Action_Data :: struct {
	name:          string,
	state:         Axis_2D_State,
	owner_binding: int,
}

Key_Binding :: struct {
	action:    Button_Action,
	key:       Key,
	modifiers: Modifiers,
}

Mouse_Button_Binding :: struct {
	action: Button_Action,
	button: Mouse_Button,
}

Button_Axis_2D_Binding :: struct {
	action:                Axis_2D_Action,
	desc:                  Button_Axis_2D_Desc,
	value:                 [2]f32,
	last_actuation_serial: u64,
}


// Input capture sources: while set for an action, dispatch skips that
// action's handlers. Queries keep returning raw state; capture only
// gates dispatch (the shader mouse uniform still reads position over UI).
Capture :: enum u8 {
	Keyboard,
	Mouse,
}

Captures :: bit_set[Capture; u8]

// When a bound action's state changes.
Trigger :: enum u8 {
	Pressed,
	Released,
	Down,
	Changed,
}

Button_Handler :: #type proc(user_data: rawptr, system: ^System, action: Button_Action)
Axis_2D_Handler :: #type proc(user_data: rawptr, system: ^System, action: Axis_2D_Action, value: [2]f32)
Window_Handler :: #type proc(user_data: rawptr, system: ^System, size, pixel_size: [2]i32)
Quit_Handler :: #type proc(user_data: rawptr, system: ^System)

Button_Handler_Entry :: struct {
	action:    Button_Action,
	trigger:   Trigger,
	handler:   Button_Handler,
	user_data: rawptr,
}

Axis_2D_Handler_Entry :: struct {
	action:    Axis_2D_Action,
	handler:   Axis_2D_Handler,
	user_data: rawptr,
}

System :: struct {
	allocator:               runtime.Allocator,
	adapter:                 Adapter,
	keys:                    [KEY_COUNT]bool,
	modifiers:               Modifiers,
	mouse_buttons:           [MOUSE_BUTTON_COUNT]bool,
	mouse_position:          [2]f32,
	pending_mouse_delta:     [2]f32,
	pending_mouse_wheel:     [2]f32,
	mouse:                   Mouse_State,
	button_actions:          [dynamic]Button_Action_Data,
	axis_2d_actions:         [dynamic]Axis_2D_Action_Data,
	key_bindings:            [dynamic]Key_Binding,
	mouse_button_bindings:   [dynamic]Mouse_Button_Binding,
	button_axis_2d_bindings: [dynamic]Button_Axis_2D_Binding,
	frame_index:             u64,
	actuation_serial:        u64,

	// Window state, fed by the adapter from window events.
	window_size:             [2]i32,
	window_pixel_size:       [2]i32,
	window_resized:          bool,
	quit_requested:          bool,
	quit_dispatched:         bool,
	focused:                 bool,
	pending_window_resized:  bool,
	pending_quit:            bool,

	// Capture filter set by the app each frame before dispatch.
	captures:                Captures,

	// --input-log: when set, dispatch logs every fired action (the
	// emission the app reacts to) alongside the raw event log the
	// adapter writes. App sets it during init; off by default.
	action_log_enabled:      bool,

	// Handlers registered on named actions and window lifecycle.
	button_handlers:         [dynamic]Button_Handler_Entry,
	axis_2d_handlers:        [dynamic]Axis_2D_Handler_Entry,
	resize_handlers:         [dynamic]Window_Handler,
	resize_handler_data:     [dynamic]rawptr,
	quit_handlers:           [dynamic]Quit_Handler,
	quit_handler_data:       [dynamic]rawptr,
}
