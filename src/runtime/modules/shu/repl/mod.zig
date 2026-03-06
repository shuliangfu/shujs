// shu:repl — 与 node:repl API 兼容，基于 readline + vm 实现交互式 REPL
//
// ========== API 兼容情况 ==========
//
// | API        | 兼容 | 说明 |
// |------------|------|------|
// | start()    | ✓    | 返回 REPLServer，使用 readline.createInterface + vm.runInContext |
// | REPLServer | ✓    | context、close、displayPrompt、on('exit')、defineCommand、write |
//

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 内嵌 REPL 启动脚本：从 globalThis.__replStartOptions 读配置，require readline/vm，创建 REPLServer 并返回
const REPL_BOOTSTRAP_SCRIPT =
    "(function(){ var opts=globalThis.__replStartOptions; if(opts==null||typeof opts!=='object')opts={}; " ++ "var req=globalThis.require; if(typeof req!=='function')throw new Error('repl.start() requires require (CJS context)'); " ++ "var rl=require('node:readline'), vm=require('node:vm'), process=globalThis.process; " ++ "var input=opts.input!==undefined?opts.input:(process&&process.stdin), output=opts.output!==undefined?opts.output:(process&&process.stdout); " ++ "if(!input||!output)throw new Error('repl.start() requires input and output streams'); " ++ "var prompt=opts.prompt!==undefined?opts.prompt:'> ', ctxObj=opts.context!==undefined?opts.context:{}, context=vm.createContext(ctxObj); " ++ "var iface=rl.createInterface({input:input,output:output}); iface.setPrompt(prompt); " ++ "var util;(function(){try{util=require('node:util');}catch(_){util=null;}})(); " ++ "var writer=opts.writer!==undefined?opts.writer:(function(v){if(util&&typeof util.inspect==='function')return util.inspect(v); return String(v);}); " ++ "var defaultEval=function(code,ctx,file,cb){try{var r=vm.runInContext(code,ctx,{filename:file||'repl'}); cb(null,r);}catch(e){cb(e,undefined);}}; " ++ "var evalFn=opts.eval!==undefined?opts.eval:defaultEval; " ++ "var s={context:context,input:input,output:output,_events:{},_commands:{}}; " ++ "s.on=function(n,f){if(!this._events[n])this._events[n]=[]; this._events[n].push(f); return this;}; " ++ "s.emit=function(n){var L=this._events[n]; if(L)for(var i=0;i<L.length;i++)L[i].apply(this,Array.prototype.slice.call(arguments,1)); return this;}; " ++ "s.close=function(){iface.close(); return this;}; s.displayPrompt=function(preserve){iface.prompt(preserve); return this;}; " ++ "s.write=function(data){if(output&&typeof output.write==='function')output.write(data); return this;}; " ++ "s.defineCommand=function(name,cmd){this._commands[name]=typeof cmd==='function'?cmd:function(){}; return this;}; " ++ "iface.on('line',function(line){var t=line.trim(); " ++ "if(t.length>0&&t[0]==='.'){var rest=t.slice(1), nm=rest.split(/\\s/)[0]||rest, c=s._commands[nm]; " ++ "if(c)c(rest.slice(nm.length).trim()); else s.write('Unknown command.\\n'); s.displayPrompt(); return;} " ++ "evalFn(t,context,'repl',function(err,result){if(err)s.write(writer(err)+'\\n'); else if(result!==undefined)s.write(writer(result)+'\\n'); s.displayPrompt();});}); " ++ "iface.on('close',function(){s.emit('exit');}); s.displayPrompt(); return s; })();";

/// repl.start(options) 或 repl.start(promptString)：设置 __replStartOptions 后执行内嵌脚本，返回 REPLServer
fn startCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_opts = jsc.JSStringCreateWithUTF8CString("__replStartOptions");
    defer jsc.JSStringRelease(k_opts);

    var options_val: jsc.JSValueRef = jsc.JSObjectMake(ctx, null, null);
    if (argumentCount >= 1) {
        const first = arguments[0];
        if (jsc.JSValueIsString(ctx, first)) {
            const k_prompt = jsc.JSStringCreateWithUTF8CString("prompt");
            defer jsc.JSStringRelease(k_prompt);
            options_val = jsc.JSObjectMake(ctx, null, null);
            _ = jsc.JSObjectSetProperty(ctx, options_val, k_prompt, first, jsc.kJSPropertyAttributeNone, null);
        } else if (!jsc.JSValueIsUndefined(ctx, first) and !jsc.JSValueIsNull(ctx, first)) {
            const obj = jsc.JSValueToObject(ctx, first, exception);
            if (obj == null) return jsc.JSValueMakeUndefined(ctx);
            options_val = first;
        }
    }
    _ = jsc.JSObjectSetProperty(ctx, global, k_opts, options_val, jsc.kJSPropertyAttributeNone, null);

    const script_z = allocator.dupeZ(u8, REPL_BOOTSTRAP_SCRIPT) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    const result = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, exception);
    return result;
}

/// 返回 shu:repl 的 exports：start、REPL_MODE_STRICT、REPL_MODE_SLOPPY、REPLServer（占位类名，实际由 start 返回实例）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "start", startCallback);
    const k_strict = jsc.JSStringCreateWithUTF8CString("REPL_MODE_STRICT");
    defer jsc.JSStringRelease(k_strict);
    const k_sloppy = jsc.JSStringCreateWithUTF8CString("REPL_MODE_SLOPPY");
    defer jsc.JSStringRelease(k_sloppy);
    const k_repl = jsc.JSStringCreateWithUTF8CString("REPLServer");
    defer jsc.JSStringRelease(k_repl);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_strict, jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("strict")), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_sloppy, jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("sloppy")), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_repl, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
