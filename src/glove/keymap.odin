package glove

import ini "core:encoding/ini"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"

// Loads key bindings from an ini file: `action = [mod+]key` per line,
// `#` comments, optional `[sections]` (parsed but ignored: reader
// organization only, e.g. `[keyboard]` / `[mouse]`). The core never
// touches SDL: key names are the Key enum's field names lowercased
// without the leading `_` (`1`, `escape`, `f1`, `lgui`); mouse buttons
// are `mouse_left|mouse_middle|mouse_right|mouse_x1|mouse_x2`;
// modifiers are `shift|ctrl|alt|gui`. One action may bind several keys:
// repeated `action = key` lines accumulate (the ini iterator is a
// stream, not a key->value map, so nothing is overwritten).
//
// The app registers its actions BEFORE calling keymap_load: unknown
// actions and invalid bindings log a warning and the loader moves on; a
// missing file warns once and leaves the system unbound.

keymap_load :: proc(system: ^System, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, system.allocator)
	if err != nil {
		log.warnf("glove keymap: cannot read %s", path)
		return false
	}
	defer delete(data)

	bound := map[string]bool{}
	it := ini.iterator_from_string(string(data), ini.Options{comment = "#"})
	for action_name, key_name in ini.iterate(&it) {
		if len(action_name) == 0 {
			log.warnf("glove keymap %s: invalid binding '%s'", path, action_name)
			continue
		}

		action, action_ok := action_find(system, action_name)
		if !action_ok {
			log.warnf("glove keymap %s: unknown action '%s'", path, action_name)
			continue
		}

		binding, bind_ok := keymap_parse_binding(key_name)
		if !bind_ok {
			log.warnf("glove keymap %s: invalid binding '%s'", path, key_name)
			continue
		}
		if mouse_button, is_mouse := keymap_mouse_button(binding.key); is_mouse {
			bind_mouse_button(system, action, mouse_button)
		} else if key, key_ok := key_from_name(binding.key); key_ok {
			bind_key(system, action, key, binding.modifiers)
		} else {
			log.warnf("glove keymap %s: invalid binding '%s'", path, key_name)
		}
		bound[action_name] = true
	}
	for action in system.button_actions {
		if _, has := bound[action.name]; !has {
			log.warnf("glove keymap: action '%s' has no binding", action.name)
		}
	}
	return true
}

// Mouse-button names, mapped onto Mouse_Button outside the Key enum.
keymap_mouse_button :: proc(name: string) -> (Mouse_Button, bool) {
	switch name {
	case "mouse_left":   return .Left, true
	case "mouse_middle": return .Middle, true
	case "mouse_right":  return .Right, true
	case "mouse_x1":     return .X1, true
	case "mouse_x2":     return .X2, true
	}
	return .Unknown, false
}

Key_Binding_Spec :: struct {
	key:       string,
	modifiers: Modifiers,
}

keymap_parse_binding :: proc(name: string) -> (Key_Binding_Spec, bool) {
	spec := Key_Binding_Spec{}
	for &part in strings.split(name, "+") {
		part = strings.trim_space(part)
		if len(part) == 0 do return spec, false
		if part == "shift" {
			spec.modifiers += {.Shift}
		} else if part == "ctrl" {
			spec.modifiers += {.Ctrl}
		} else if part == "alt" {
			spec.modifiers += {.Alt}
		} else if part == "gui" {
			spec.modifiers += {.Gui}
		} else {
			if len(spec.key) != 0 do return spec, false
			spec.key = part
		}
	}
	if len(spec.key) == 0 do return spec, false
	return spec, true
}

// Resolves a key name against the Key enum's field names (leading `_`
// stripped, so `_1` matches "1"). UNKNOWN and COUNT never resolve.
// Compares without allocating (context-free ASCII lowercase).
key_from_name :: proc(name: string) -> (Key, bool) {
	for field in reflect.enum_fields_zipped(Key) {
		field_name := field.name
		if len(field_name) > 0 && field_name[0] == '_' do field_name = field_name[1:]
		if keymap_name_equal(field_name, name) {
			key := Key(i64(field.value))
			if key == .UNKNOWN || key == .COUNT do break
			return key, true
		}
	}
	return .UNKNOWN, false
}

keymap_name_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		ca := a[i] | ('a' - 'A') if a[i] >= 'A' && a[i] <= 'Z' else a[i]
		cb := b[i] | ('a' - 'A') if b[i] >= 'A' && b[i] <= 'Z' else b[i]
		if ca != cb do return false
	}
	return true
}
