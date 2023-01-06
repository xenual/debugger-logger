package main

import "core:os"
import win32 "core:sys/windows"

//
//  Win32 setup
//

foreign import kernel32 "system:Kernel32.lib"
foreign kernel32 {
    @(link_name="AttachConsole")
    win32_AttachConsole :: proc (dwProcessId: win32.DWORD) -> win32.BOOL ---
    @(link_name="AllocConsole")
    win32_AllocConsole :: proc () -> win32.BOOL ---
}

win32_open_console_or_attach_to_parent :: proc(open_console :bool = true) {
    ok := win32_AttachConsole(0xFFFF_FFFF)
    if !ok && open_console {
		when !ODIN_DEBUG do win32_AllocConsole()
    }

    os.stdin  = os.get_std_handle(uint(win32.STD_INPUT_HANDLE))
    os.stdout = os.get_std_handle(uint(win32.STD_OUTPUT_HANDLE))
    os.stderr = os.get_std_handle(uint(win32.STD_ERROR_HANDLE))
}

//
// Custom logger to Console (unsafe) + Debugger (thread safe: OutputDebugStringW)
//

import "core:fmt"
import "core:strings"
import "core:runtime"
import "core:time"
import "core:log"

// I removed the "---" from the original logger.
Debugger_Level_Headers := [?]string{
	0..<10 = "[DEBUG] ",
   10..<20 = "[INFO ] ",
   20..<30 = "[WARN ] ",
   30..<40 = "[ERROR] ",
   40..<50 = "[FATAL] ",
}

debugger_do_level_header :: proc(opts: log.Options, level: log.Level, str: ^strings.Builder) {

	RESET     :: "\x1b[0m"
	RED       :: "\x1b[31m"
	YELLOW    :: "\x1b[33m"
	DARK_GREY :: "\x1b[90m"

	col := RESET
	switch level {
	case .Debug:   col = DARK_GREY
	case .Info:    col = RESET
	case .Warning: col = YELLOW
	case .Error, .Fatal: col = RED
	}

	if .Level in opts {
		if .Terminal_Color in opts {
			fmt.sbprint(str, col)
		}
		fmt.sbprint(str, Debugger_Level_Headers[level])
		if .Terminal_Color in opts {
			fmt.sbprint(str, RESET)
		}
	}
}

/// ================ Customizable Options ================

/*
Logger_Option :: enum {
	Level,
	Date,
	Time,
	Short_File_Path,
	Long_File_Path,
	Line,
	Procedure,
	Terminal_Color,
	Thread_Id,
}
*/

Default_Logger_Opts_For_Console :: log.Options{
	.Level,
	.Terminal_Color,
	.Short_File_Path,
	.Line,
	//.Procedure,
	// .Date,
	.Time,
}

Default_Logger_Opts_For_Debugger :: log.Options{
	.Level,
	.Short_File_Path,
	.Line,
	//.Procedure,
	// .Date,
	.Time,
}

/// =========================================

Debugger_Logger_Data :: struct {
	file_handle:  os.Handle,
	ident: string,
    // I didn't want to restructure the code arount multi_logger,
    // and Logger.options can store Options one so I put them here.
    console_opts: log.Options,
    debugger_opts: log.Options,
}

create_debugger_logger :: proc(lowest := log.Level.Debug, console_opts := Default_Logger_Opts_For_Console, debugger_opts := Default_Logger_Opts_For_Debugger, ident := "") -> log.Logger {
	data := new(Debugger_Logger_Data)
	data.file_handle = os.INVALID_HANDLE
	data.ident = ident
    data.console_opts = console_opts
    data.debugger_opts = debugger_opts
	return log.Logger{debugger_logger_proc, data, lowest, nil}
}

destroy_debugger_logger :: proc(log: ^log.Logger) {
	free(log.data)
}

debugger_logger_proc :: proc(logger_data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	data := cast(^Debugger_Logger_Data)logger_data

	h: os.Handle = os.stdout /* if level <= Level.Error else os.stderr */
	if data.file_handle != os.INVALID_HANDLE {
		h = data.file_handle
	}

	//backing: [1024]byte //NOTE(Hoej): 1024 might be too much for a header backing, unless somebody has really long paths.
    MAX_HEADER_SIZE :: 1024

    backing := make(T=[]byte, len=MAX_HEADER_SIZE+len(text)+1, allocator=context.temp_allocator)
    { 
        // Console print
        buf := strings.builder_from_bytes(backing[:])

        buffer_format_header_from_opts(&buf, logger_data, level, text, data.console_opts, location)
        assert(strings.builder_len(buf) <= MAX_HEADER_SIZE)
        fmt.sbprintf(&buf, "%s\n", text)

        //TODO(Hoej): When we have better atomics and such, make this thread-safe
        fmt.fprint(h, strings.to_string(buf))
    }

    when ODIN_DEBUG {
        // Debugger print
        buf := strings.builder_from_bytes(backing[:]) // 2nd time resets builder

        buffer_format_header_from_opts(&buf, logger_data, level, text, data.debugger_opts, location)
        assert(strings.builder_len(buf) <= MAX_HEADER_SIZE)
        fmt.sbprintf(&buf, "%s\n", text)

        // OutputDebugStringW is thread safe, I used  a single builder to call this in a single call.
        win32.OutputDebugStringW(win32.utf8_to_wstring(strings.to_string(buf)))
    }
}

//
// This from core:log/file_console_logger.odin[file_console_logger_proc], I extracted the formatting code to make it stream-independent.
// 
buffer_format_header_from_opts:: proc(buf: ^strings.Builder, logger_data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
    data := cast(^log.File_Console_Logger_Data)logger_data
	
	debugger_do_level_header(options, level, buf)

	when time.IS_SUPPORTED {
		if log.Full_Timestamp_Opts & options != nil {
			fmt.sbprint(buf, "[")
			t := time.now()
			y, m, d := time.date(t)
			h, min, s := time.clock(t)
			if .Date in options { fmt.sbprintf(buf, "%d-%02d-%02d ", y, m, d)    }
			if .Time in options { fmt.sbprintf(buf, "%02d:%02d:%02d", h, min, s) }
			fmt.sbprint(buf, "] ")
		}
	}

	log.do_location_header(options, buf, location)

	if .Thread_Id in options {
		// NOTE(Oskar): not using context.thread_id here since that could be
		// incorrect when replacing context for a thread.
		fmt.sbprintf(buf, "[{}] ", os.current_thread_id())
	}

	if data.ident != "" {
		fmt.sbprintf(buf, "[%s] ", data.ident)
	}
}
