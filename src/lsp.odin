// Minimal LSP client for slangd (--stdio, JSON-RPC with Content-Length
// framing). Synchronous request/response: the editor's autocomplete callback
// runs on the render thread and slangd answers in milliseconds locally, so
// a blocking round trip is acceptable for the workbench (the async path,
// suggestionsPromise, is the follow-up if latency ever shows).
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

Lsp :: struct {
	process:      os.Process,
	stdin:        ^os.File,
	stdout:       ^os.File,
	next_id:      int,
	open_uri:     string, // document currently didOpen-ed
	version:      int,    // didChange version counter
	// Responses routed by lsp_drain (keyed by request id) and live
	// publishDiagnostics per file (keyed by rel path like "scenes/apple").
	pending:      map[int]string,
	diagnostics:  map[string][dynamic]LspDiagnostic,
	diag_version: int,
}

LspDiagnostic :: struct {
	line:      int, // 0-based
	col_start: int,
	end_line:  int,
	col_end:   int,
	severity:  int, // 1 error, 2 warning
	msg:       string,
}

LspCompletion :: struct {
	label:  string,
	detail: string,
}

lsp_write_msg :: proc(client: ^Lsp, body: string) -> bool {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	if _, write_err := os.write(client.stdin, transmute([]u8)header); write_err != nil {
		return false
	}
	_, write_err := os.write(client.stdin, transmute([]u8)body)
	return write_err == nil
}

// Reads one framed message. Blocks on the pipe; the caller bounds the wait
// by only calling this when a response is due.
lsp_read_msg :: proc(client: ^Lsp, dest: []u8) -> (msg_len: int, read_ok: bool) {
	// Header: "Content-Length: N\r\n\r\n".
	header: [128]u8
	header_len := 0
	for header_len < len(header) - 1 {
		byte_in: [1]u8
		read_n, read_err := os.read(client.stdout, byte_in[:])
		if read_err != nil || read_n != 1 do return 0, false
		header[header_len] = byte_in[0]
		header_len += 1
		if header_len >= 4 && string(header[header_len - 4:header_len]) == "\r\n\r\n" do break
	}
	length := -1
	header_line := string(header[:header_len])
	if strings.has_prefix(header_line, "Content-Length:") {
		length_text := strings.trim_space(header_line[len("Content-Length:"):])
		length_text = strings.trim_suffix(length_text, "\r\n\r\n")
		length, _ = strconv_parse_int(length_text)
	}
	if length <= 0 || length > len(dest) do return 0, false
	total := 0
	for total < length {
		read_n, read_err := os.read(client.stdout, dest[total:length])
		if read_err != nil || read_n <= 0 do return 0, false
		total += read_n
	}
	return total, true
}

strconv_parse_int :: proc(text: string) -> (int, bool) {
	value := 0
	for digit in text {
		if digit < '0' || digit > '9' do return 0, false
		value = value * 10 + int(digit - '0')
	}
	return value, true
}

lsp_request :: proc(client: ^Lsp, method: string, params: string) -> (request_id: int, write_ok: bool) {
	client.next_id += 1
	request_id = client.next_id
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}}`,
		request_id,
		method,
		params,
	)
	return request_id, lsp_write_msg(client, body)
}

lsp_notify :: proc(client: ^Lsp, method: string, params: string) -> bool {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","method":"%s","params":%s}}`, method, params)
	return lsp_write_msg(client, body)
}

// Non-blocking: routes every queued message: responses land in `pending`
// by id, publishDiagnostics land in `diagnostics` by file.
lsp_drain :: proc(client: ^Lsp) {
	for {
		has_data, poll_err := os.pipe_has_data(client.stdout)
		if poll_err != nil || !has_data do break
		recv_buf := make([]u8, 256 * 1024, context.temp_allocator)
		msg_len, read_ok := lsp_read_msg(client, recv_buf)
		if !read_ok do break
		lsp_route_message(client, string(recv_buf[:msg_len]))
	}
}

lsp_route_message :: proc(client: ^Lsp, raw_msg: string) {
	Env :: struct {
		id:     json.Value `json:"id"`,
		method: string `json:"method"`,
		params: json.Value `json:"params"`,
	}
	envelope: Env
	if json.unmarshal_string(raw_msg, &envelope) != nil do return
	if resp_id, is_int := envelope.id.(json.Integer); is_int {
		client.pending[int(resp_id)] = strings.clone(raw_msg)
		return
	}
	log.debugf("[lsp] notification: %s (%d bytes)", envelope.method, len(raw_msg))
	if envelope.method == "textDocument/publishDiagnostics" {
		lsp_handle_diagnostics(client, envelope.params)
	}
}

lsp_handle_diagnostics :: proc(client: ^Lsp, params: json.Value) {
	obj, is_obj := params.(json.Object)
	if !is_obj do return
	uri_val, has_uri := obj["uri"]
	uri, is_str := uri_val.(string)
	if !has_uri || !is_str do return
	// Map the uri back to our rel path (".../src/shaders/scenes/apple.slang").
	rel_path := uri
	if shaders_idx := strings.index(rel_path, "src/shaders/"); shaders_idx >= 0 {
		rel_path = rel_path[shaders_idx + len("src/shaders/"):]
	}
	rel_path = strings.trim_suffix(rel_path, ".slang")
	for {
		updown_idx := strings.index(rel_path, "/../")
		if updown_idx < 0 do break
		prev_slash := strings.last_index(rel_path[:updown_idx], "/")
		if prev_slash < 0 {
			rel_path = rel_path[updown_idx + 4:]
			break
		}
		rel_path = strings.concatenate({rel_path[:prev_slash], rel_path[updown_idx + 3:]}, context.temp_allocator)
	}

	diags := make([dynamic]LspDiagnostic, context.temp_allocator)
	arr_val, has_arr := obj["diagnostics"]
	arr, is_arr := arr_val.(json.Array)
	if has_arr && is_arr {
		for dval in arr {
			dobj, is_dobj := dval.(json.Object)
			if !is_dobj do continue
			diag := LspDiagnostic{severity = 1}
			if rng_val, has_range := dobj["range"]; has_range {
				if rng, is_rng := rng_val.(json.Object); is_rng {
					if start_pos, start_ok := rng["start"].(json.Object); start_ok {
						diag.line = lsp_json_int(start_pos["line"])
						diag.col_start = lsp_json_int(start_pos["character"])
					}
					if end_pos, end_ok := rng["end"].(json.Object); end_ok {
						diag.end_line = lsp_json_int(end_pos["line"])
						diag.col_end = lsp_json_int(end_pos["character"])
					}
				}
			}
			if severity_val, has_severity := dobj["severity"]; has_severity {
				diag.severity = lsp_json_int(severity_val)
			}
			if message_val, has_message := dobj["message"]; has_message {
				if message_text, is_msg_str := message_val.(string); is_msg_str {
					diag.msg = strings.clone(message_text)
				}
			}
			append(&diags, diag)
		}
	}
	// Replace the file's set (an empty publish clears stale squiggles).
	if rel_path in client.diagnostics {
		delete(client.diagnostics[rel_path])
	}
	client.diagnostics[strings.clone(rel_path)] = diags
	client.diag_version += 1
}

lsp_json_int :: proc(value: json.Value) -> int {
	if int_val, is_int := value.(json.Integer); is_int do return int(int_val)
	return 0
}

// Reads messages until the response for `want_id` arrives; notifications
// (no id) are skipped. Returns the raw JSON of the response. slangd pretty-
// prints its JSON ("id" : 1, with spaces), so the id is parsed, not matched
// as text.
lsp_await_response :: proc(client: ^Lsp, want_id: int) -> (string, bool) {
	for attempt in 0 ..< 1000 {
		if pending_msg, found := client.pending[want_id]; found {
			delete_key(&client.pending, want_id)
			return pending_msg, true
		}
		lsp_drain(client)
		time.sleep(2 * time.Millisecond)
	}
	return "", false
}

lsp_start :: proc() -> ^Lsp {
	client := new(Lsp)
	in_r, in_w, in_err := os.pipe()
	out_r, out_w, out_err := os.pipe()
	if in_err != nil || out_err != nil {
		log.errorf("lsp: pipe failed: %v %v", in_err, out_err)
		return nil
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	handle, start_err := os.process_start(
		{
			working_dir = cwd,
			command = []string{"vendor/slang/bin/slangd", "--stdio"},
			stdin = in_r,
			stdout = out_w,
		},
	)
	if start_err != nil {
		log.errorf("lsp: failed to start slangd: %v", start_err)
		return nil
	}
	client.process = handle
	client.stdin = in_w
	client.stdout = out_r

	root := fmt.tprintf("file://%s", cwd)
	root_json, _ := json.marshal(root, allocator = context.temp_allocator)
	init_params := fmt.tprintf(
		`{{"processId":null,"rootUri":%s,"capabilities":{{"textDocument":{{"completion":{{"completionItem":{{"snippetSupport":false}}}},"publishDiagnostics":{{"relatedInformation":true,"versionSupport":true}}}}}}}}`,
		root_json,
	)
	init_id, write_ok := lsp_request(client, "initialize", init_params)
	if !write_ok {
		log.error("lsp: initialize write failed")
		return nil
	}
	init_resp, got_response := lsp_await_response(client, init_id)
	if !got_response {
		log.error("lsp: initialize response timeout")
		return nil
	}
	log.infof("[lsp] server capabilities: %s", init_resp[:min(400, len(init_resp))])
	lsp_notify(client, "initialized", `{}`)
	log.info("[lsp] slangd initialized")
	return client
}

lsp_escape_json :: proc(text: string) -> string {
	escaped, _ := json.marshal(text, allocator = context.temp_allocator)
	return string(escaped)
}

// Full-sync the document. slangd (2026.18.2) accumulates one compilation
// per didChange instead of replacing the document: every sync merges
// another copy of the file's declarations into the scope, producing
// phantom "conflicts with existing declaration" / "ambiguous reference"
// diagnostics on every top-level symbol (verified: 1 change = 2 copies,
// 2 changes = 3). The workaround is a reset cycle per sync: didClose,
// didOpen with an empty buffer, then one full-text didChange, which
// leaves exactly one compilation of the document on the server.
lsp_sync :: proc(client: ^Lsp, doc_uri: string, doc_text: string) {
	text_json := lsp_escape_json(doc_text)
	uri_json := lsp_escape_json(doc_uri)
	if client.open_uri == doc_uri {
		params := fmt.tprintf(`{{"textDocument":{{"uri":%s}}}}`, uri_json)
		lsp_notify(client, "textDocument/didClose", params)
		delete(client.open_uri)
		client.open_uri = ""
	}
	if client.open_uri != doc_uri {
		params := fmt.tprintf(
			`{{"textDocument":{{"uri":%s,"languageId":"slang","version":1,"text":""}}}}`,
			uri_json,
		)
		lsp_notify(client, "textDocument/didOpen", params)
		delete(client.open_uri)
		client.open_uri = strings.clone(doc_uri)
		client.version = 1
	}
	client.version += 1
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":[{{"text":%s}}]}}`,
		uri_json,
		client.version,
		text_json,
	)
	lsp_notify(client, "textDocument/didChange", params)
}

// Completion at (line, col), 0-based. Returns labels (caller frees the slice's
// backing array with temp allocator).
lsp_complete :: proc(client: ^Lsp, doc_uri: string, doc_text: string, line, column: int) -> []LspCompletion {
	lsp_sync(client, doc_uri, doc_text)
	uri_json := lsp_escape_json(doc_uri)
	params := fmt.tprintf(
		`{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}}}`,
		uri_json,
		line,
		column,
	)
	request_id, write_ok := lsp_request(client, "textDocument/completion", params)
	if !write_ok do return nil
	resp_body, got_response := lsp_await_response(client, request_id)
	if !got_response do return nil

	// result may be CompletionItem[] or CompletionList { items: [] }.
	Resp :: struct {
		result: json.Value `json:"result"`,
	}
	response: Resp
	if json.unmarshal_string(resp_body, &response) != nil do return nil
	items_val: json.Value
	#partial switch result_val in response.result {
	case json.Array:
		items_val = response.result
	case json.Object:
		items_val = result_val["items"]
	}
	arr, is_arr := items_val.(json.Array)
	if !is_arr do return nil
	completions := make([dynamic]LspCompletion, 0, len(arr), context.temp_allocator)
	for item_val in arr {
		obj, is_obj := item_val.(json.Object)
		if !is_obj do continue
		label: string
		if label_val, has_label := obj["label"]; has_label {
			if label_text, is_label_str := label_val.(string); is_label_str do label = label_text
		}
		if label == "" do continue
		detail: string
		if detail_val, has_detail := obj["detail"]; has_detail {
			if detail_text, is_detail_str := detail_val.(string); is_detail_str do detail = detail_text
		}
		append(&completions, LspCompletion{label = strings.clone(label, context.temp_allocator), detail = strings.clone(detail, context.temp_allocator)})
	}
	return completions[:]
}
