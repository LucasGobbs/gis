package glove

import "base:runtime"

Adapter_Register_Event_Proc :: #type proc(
	user_data: rawptr,
	system: ^System,
	event: rawptr,
) -> bool

Adapter_Update_Proc :: #type proc(user_data: rawptr, system: ^System)
Adapter_Destroy_Proc :: #type proc(user_data: rawptr, allocator: runtime.Allocator)

Adapter :: struct {
	event_type:     typeid,
	user_data:      rawptr,
	register_event: Adapter_Register_Event_Proc,
	update:         Adapter_Update_Proc,
	destroy:        Adapter_Destroy_Proc,
}

register_event :: proc(system: ^System, event: ^$Event) -> bool {
	assert(system != nil)
	assert(system.adapter.register_event != nil)
	assert(system.adapter.event_type == typeid_of(Event))
	return system.adapter.register_event(system.adapter.user_data, system, rawptr(event))
}

register_events :: proc(system: ^System, events: []$Event) -> int {
	consumed := 0
	for &event in events {
		if register_event(system, &event) do consumed += 1
	}
	return consumed
}
