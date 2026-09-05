import CoreGraphics
import Foundation
import IMECore

/// 系统级 Shift 轻点监听(CGEventTap listen-only,不吞事件)。
/// 为什么不用 IMK: Electron/Chromium 系应用(VSCode/Chrome/ZCode)不向输入法转发修饰键事件,
/// IMK handle() 在这些应用里永远收不到 flagsChanged(recognizedEvents 声明也无效,实测 0 事件);
/// AppKit 应用虽可收到,但行为不一致。listen-only tap 全局一致,代价是需要一次性授权:
/// 系统设置 → 隐私与安全性 → 输入监控(或辅助功能)→ 添加 AFM拼音。
enum ShiftModeMonitor {
    static var tap: CFMachPort?
    static var shiftDown = false   // shift 按住中
    static var shiftUsed = false   // 按住期间按过其他键 → 松开不算轻点

    static func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: shiftTapCallback, userInfo: nil) else {
            let msg = "Shift 中英监听未生效 — 请在 系统设置 → 隐私与安全性 → 输入监控 添加 AFM拼音"
            DebugLog.error(msg)
            NSLog("[AFM] %@", msg)
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        DebugLog.log("ShiftTap: 监听已启动(session tap, listen-only)")
    }

    /// 权限补授后无需重启进程,焦点切换时重试创建
    static func retryIfNeeded() {
        if tap == nil { start() }
    }

    static func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .flagsChanged:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard kc == 56 || kc == 60 else { return } // 左/右 Shift
            if event.flags.contains(CGEventFlags.maskShift) {
                shiftDown = true
                DebugLog.log("ShiftTap: shift 按下 kc=\(kc)")
            } else if shiftDown {
                shiftDown = false
                if !shiftUsed {
                    DebugLog.log("ShiftTap: 轻点 Shift → 切换中英")
                    DispatchQueue.main.async { InputController.shiftTappedToggle() }
                }
                shiftUsed = false
            }
        case .keyDown:
            // Shift 组合键(如 Shift+A / Shift+标点),松开时不切换中英
            if event.flags.contains(CGEventFlags.maskShift) { shiftUsed = true }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        default:
            break
        }
    }
}

private func shiftTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                              _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    ShiftModeMonitor.handle(type, event)
    return Unmanaged.passUnretained(event)
}
