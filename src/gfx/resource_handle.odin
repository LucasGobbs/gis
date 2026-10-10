package gfx

Resource_Handle :: struct {
	index:      u32,
	generation: u32,
}

Buffer_Handle :: distinct Resource_Handle
Texture_Handle :: distinct Resource_Handle
Sampler_Handle :: distinct Resource_Handle

Handle_Slot :: struct {
	generation: u32,
	alive:      bool,
}

Handle_Pool :: struct {
	slots: [dynamic]Handle_Slot,
	free:  [dynamic]u32,
}

handle_pool_acquire :: proc(pool: ^Handle_Pool) -> Resource_Handle {
	if len(pool.free) > 0 {
		index := pop(&pool.free)
		slot := &pool.slots[index]
		assert(!slot.alive)
		slot.alive = true
		return {index = index, generation = slot.generation}
	}

	index := u32(len(pool.slots))
	append(&pool.slots, Handle_Slot{generation = 1, alive = true})
	return {index = index, generation = 1}
}

handle_pool_contains :: proc(pool: ^Handle_Pool, handle: Resource_Handle) -> bool {
	if handle.generation == 0 || int(handle.index) >= len(pool.slots) do return false
	slot := pool.slots[handle.index]
	return slot.alive && slot.generation == handle.generation
}

handle_pool_release :: proc(pool: ^Handle_Pool, handle: Resource_Handle) -> bool {
	if !handle_pool_contains(pool, handle) do return false
	slot := &pool.slots[handle.index]
	slot.alive = false
	slot.generation += 1
	if slot.generation == 0 do slot.generation = 1
	append(&pool.free, handle.index)
	return true
}

handle_pool_destroy :: proc(pool: ^Handle_Pool) {
	delete(pool.slots)
	delete(pool.free)
	pool^ = {}
}
