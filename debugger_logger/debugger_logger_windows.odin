package debugger_logger

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
//  Debugger Logger
//

import "core:fmt"
import "core:strings"
import "core:runtime"
import "core:time"
import "core:log"

Level       :: runtime.Logger_Level
Option      :: runtime.Logger_Option
Options     :: runtime.Logger_Options
Logger_Proc :: runtime.Logger_Proc
Logger      :: runtime.Logger


// I removed the "---" from the original logger.
Debugger_Level_Headers := [?]string{
     0..<10 = "[DEBUG] ",
    10..<20 = "[INFO ] ",
    20..<30 = "[WARN ] ",
    30..<40 = "[ERROR] ",
    40..<50 = "[FATAL] ",
}

/// ================ Customizable Options ================

/*
runtime.Logger_Option :: enum {
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

Default_Logger_Opts_For_Console :: Options{
    .Level,
    .Terminal_Color,
    .Short_File_Path,
    .Line,
    //.Procedure,
    // .Date,
    .Time,
}

Default_Logger_Opts_For_Debugger :: Options{
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
    console_opts: Options,
    debugger_opts: Options,
    padding: int,
}

create_debugger_logger :: proc(lowest := Level.Debug, console_opts := Default_Logger_Opts_For_Console, debugger_opts := Default_Logger_Opts_For_Debugger, ident := "", padding := 0) -> Logger {
    win32_open_console_or_attach_to_parent()
    
    data := new(Debugger_Logger_Data)
    data.file_handle = os.INVALID_HANDLE
    data.ident = ident
    data.console_opts = console_opts
    data.debugger_opts = debugger_opts
    data.padding = padding
    return Logger{debugger_logger_proc, data, lowest, nil}
}

destroy_debugger_logger :: proc(log: ^Logger) {
    free(log.data)
}

debugger_logger_proc :: proc(logger_data: rawptr, level: Level, text: string, options: Options, location := #caller_location) {
    data := cast(^Debugger_Logger_Data)logger_data

    h: os.Handle = os.stdout /* if level <= Level.Error else os.stderr */
    if data.file_handle != os.INVALID_HANDLE {
        h = data.file_handle
    }

    // (original) NOTE(Hoej): 1024 might be too much for a header backing, unless somebody has really long paths.
    MAX_HEADER_SIZE :: 1024

    // OutputDebugStringW is thread safe, but in order to do a single call we must to print everything in to a single buffer.
    // (The original code would have forced us to do multiple calls, or allocate a 3rd time with concatenate())
    max_length := MAX_HEADER_SIZE + len(text) + 1 /* "\n" */
    backing := make(T=[]byte, len=max_length, allocator=context.temp_allocator)
    defer delete(backing)

    { 
        // Console print
        buf := strings.builder_from_bytes(backing[:])
        
        buffer_format_header_from_opts(&buf, logger_data, level, data.console_opts, location)        
        assert(strings.builder_len(buf) <= MAX_HEADER_SIZE)
        fmt.sbprintf(&buf, "%s\n", text)

        //TODO(Hoej): When we have better atomics and such, make this thread-safe
        fmt.fprint(h, strings.to_string(buf))
    }

    when ODIN_DEBUG {
        // Debugger print
        buf := strings.builder_from_bytes(backing[:]) // 2nd time resets builder

        buffer_format_header_from_opts(&buf, logger_data, level, data.debugger_opts, location)
        assert(strings.builder_len(buf) <= MAX_HEADER_SIZE)
        fmt.sbprintf(&buf, "%s\n", text)

        win32.OutputDebugStringW(win32.utf8_to_wstring(strings.to_string(buf)))
    }
}

//
// This from core:log/file_console_logger.odin[file_console_logger_proc], I extracted the formatting code to make it stream-independent.
// 
buffer_format_header_from_opts:: proc(buf: ^strings.Builder, logger_data: rawptr, level: Level, options: Options, location := #caller_location) {
    data := cast(^Debugger_Logger_Data)logger_data
    
    debugger_do_level_header(options, level, buf)

    when time.IS_SUPPORTED {
        if options & {.Date, .Time} != nil {
            fmt.sbprint(buf, "[")
            t := time.now()
            y, m, d := time.date(t)
            h, min, s := time.clock(t)
            if .Date in options { fmt.sbprintf(buf, "%d-%02d-%02d ", y, m, d)    }
            if .Time in options { fmt.sbprintf(buf, "%02d:%02d:%02d", h, min, s) }
            fmt.sbprint(buf, "] ")
        }
    }

    do_location_header(options, buf, data.padding, location)

    if .Thread_Id in options {
        // NOTE(Oskar): not using context.thread_id here since that could be
        // incorrect when replacing context for a thread.
        fmt.sbprintf(buf, "[{}] ", os.current_thread_id())
    }

    if data.ident != "" {
        fmt.sbprintf(buf, "[%s] ", data.ident)
    }
}

debugger_do_level_header :: proc(opts: Options, level: Level, str: ^strings.Builder) {

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

do_location_header :: proc(opts: Options, buf: ^strings.Builder, padding: int, location := #caller_location) {
	if opts & {.Short_File_Path, .Long_File_Path, .Line, .Procedure} == nil {
		return
	}
	fmt.sbprint(buf, "[")

	file := location.file_path
	if .Short_File_Path in opts {
		last := 0
		for r, i in location.file_path {
			if r == '/' {
				last = i+1
			}
		}
		file = location.file_path[last:]
	}

    prev_pos := strings.builder_len(buf^)

    add_sep := false
	if opts & {.Short_File_Path, .Long_File_Path} != nil {
        fmt.sbprint(buf, file)
        add_sep = true
	}

    if .Line in opts {
        if add_sep {
            fmt.sbprint(buf, ":")
            add_sep = false
        } 
		fmt.sbprint(buf, location.line)
        add_sep = true
	}

	if .Procedure in opts {
		if add_sep {
            fmt.sbprint(buf, ":")
            add_sep = false
        } 
		fmt.sbprintf(buf, "%s()", location.procedure)
	}

    // add padding
    width := strings.builder_len(buf^) - prev_pos
    pad   := max(padding - width, 0)
    for i := 0; i < padding - width ; i += 1 {        
        append(&(buf.buf), ' ')
    }

	fmt.sbprint(buf, "] ")
}
