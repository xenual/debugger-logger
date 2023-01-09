# Debugger logger for Odin

Dual logging to STDOUT and the debugger console using OutputDebugStringW.  
Also provides a function to attach to the standard output of the parent window.  

Example:  
```odin
package main

import "core:log"
import "debugger_logger"

main :: proc() {
    // calls `debugger_logger.win32_open_console_or_attach_to_parent()`
    context.logger = debugger_logger.create_debugger_logger(padding=20)

    log.info("[glfw] Context created.")
    // $ [INFO ] [09:12:22] [main.odin:9         ] [glfw] Context created.
}

```

Debugger output (outdated):  

<img src="./images/example.png" width="400rem"/>
