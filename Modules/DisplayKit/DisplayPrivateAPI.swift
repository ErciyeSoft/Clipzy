import AppKit
import CoreGraphics
import Foundation
import IOKit

/// The only file in DisplayKit that touches interfaces macOS doesn't publish.
///
/// - DisplayServices (private framework): brightness of the built-in display and Apple displays.
/// - IOAVService (IOKit, Apple silicon): I²C to external displays, used for DDC/CI.
/// - CGVirtualDisplay (CoreGraphics): virtual displays.
///
/// Every symbol is looked up at run time, so a macOS release that removes one turns the
/// matching feature off instead of crashing the app.
nonisolated enum PrivateDisplayAPI {
  // MARK: - Lookup

  nonisolated(unsafe) private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
  nonisolated(unsafe) private static let displayServicesHandle = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
  )

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  // MARK: - DisplayServices brightness

  private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
  private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

  private static let canChangeBrightnessFn =
    symbol(displayServicesHandle, "DisplayServicesCanChangeBrightness", as: CanChangeBrightness.self)
  private static let getBrightnessFn =
    symbol(displayServicesHandle, "DisplayServicesGetBrightness", as: GetBrightness.self)
  private static let setBrightnessFn =
    symbol(displayServicesHandle, "DisplayServicesSetBrightness", as: SetBrightness.self)

  /// True for displays whose backlight macOS drives itself (built-in, Studio Display, Pro Display XDR).
  static func canChangeNativeBrightness(_ display: CGDirectDisplayID) -> Bool {
    guard let canChangeBrightnessFn, getBrightnessFn != nil, setBrightnessFn != nil else { return false }
    return canChangeBrightnessFn(display)
  }

  /// Brightness from 0 to 1, or nil when the display has no native control.
  static func nativeBrightness(_ display: CGDirectDisplayID) -> Double? {
    guard let getBrightnessFn else { return nil }
    var value: Float = 0
    guard getBrightnessFn(display, &value) == 0 else { return nil }
    return Double(value)
  }

  @discardableResult
  static func setNativeBrightness(_ display: CGDirectDisplayID, _ value: Double) -> Bool {
    guard let setBrightnessFn else { return false }
    return setBrightnessFn(display, Float(min(1, max(0, value)))) == 0
  }

  // MARK: - IOAVService (I²C over the display controller on Apple silicon)

  private typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
  private typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

  private static let avCreateFn =
    symbol(defaultHandle, "IOAVServiceCreateWithService", as: AVServiceCreate.self)
  private static let avReadFn =
    symbol(defaultHandle, "IOAVServiceReadI2C", as: AVServiceI2C.self)
  private static let avWriteFn =
    symbol(defaultHandle, "IOAVServiceWriteI2C", as: AVServiceI2C.self)

  static var supportsAVService: Bool { avCreateFn != nil && avReadFn != nil && avWriteFn != nil }

  /// An I²C channel for a `DCPAVServiceProxy` registry entry.
  static func makeAVService(for service: io_service_t) -> CFTypeRef? {
    avCreateFn?(kCFAllocatorDefault, service)?.takeRetainedValue()
  }

  static func avWrite(_ service: CFTypeRef, chip: UInt32, offset: UInt32, _ bytes: [UInt8]) -> Bool {
    guard let avWriteFn else { return false }
    var buffer = bytes
    return buffer.withUnsafeMutableBytes { avWriteFn(service, chip, offset, $0.baseAddress!, UInt32($0.count)) } == kIOReturnSuccess
  }

  static func avRead(_ service: CFTypeRef, chip: UInt32, offset: UInt32, count: Int) -> [UInt8]? {
    guard let avReadFn else { return nil }
    var buffer = [UInt8](repeating: 0, count: count)
    let result = buffer.withUnsafeMutableBytes { avReadFn(service, chip, offset, $0.baseAddress!, UInt32(count)) }
    return result == kIOReturnSuccess ? buffer : nil
  }

  // MARK: - CGVirtualDisplay

  static var supportsVirtualDisplays: Bool {
    ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
      .allSatisfy { NSClassFromString($0) != nil }
  }

  struct VirtualDisplaySpec {
    var name: String
    var maxPixelsWide: UInt32
    var maxPixelsHigh: UInt32
    var sizeInMillimeters: CGSize
    var vendorID: UInt32
    var productID: UInt32
    var serialNumber: UInt32
    var hiDPI: Bool
    /// Width, height (points) and refresh rate of each mode.
    var modes: [(width: UInt32, height: UInt32, refreshRate: Double)]
  }

  private typealias InitWithObject = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer) -> UnsafeRawPointer?
  private typealias InitMode = @convention(c) (UnsafeRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeRawPointer?
  private typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

  /// Creates a virtual display. It exists for as long as the returned object is alive.
  @MainActor
  static func makeVirtualDisplay(_ spec: VirtualDisplaySpec) -> (object: NSObject, displayID: CGDirectDisplayID)? {
    guard supportsVirtualDisplays,
          let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
          let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
          let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
          let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else { return nil }

    let descriptor = descriptorClass.init()
    descriptor.setValue(DispatchQueue.main, forKey: "queue")
    descriptor.setValue(spec.name, forKey: "name")
    descriptor.setValue(NSNumber(value: spec.maxPixelsWide), forKey: "maxPixelsWide")
    descriptor.setValue(NSNumber(value: spec.maxPixelsHigh), forKey: "maxPixelsHigh")
    descriptor.setValue(NSValue(size: spec.sizeInMillimeters), forKey: "sizeInMillimeters")
    descriptor.setValue(NSNumber(value: spec.vendorID), forKey: "vendorID")
    descriptor.setValue(NSNumber(value: spec.productID), forKey: "productID")
    descriptor.setValue(NSNumber(value: spec.serialNumber), forKey: "serialNum")

    let initDescriptor = NSSelectorFromString("initWithDescriptor:")
    guard let initDescriptorIMP = class_getInstanceMethod(displayClass, initDescriptor).map(method_getImplementation),
          let created = unsafeBitCast(initDescriptorIMP, to: InitWithObject.self)(
            allocate(displayClass), initDescriptor, UnsafeRawPointer(Unmanaged.passUnretained(descriptor).toOpaque())
          ) else { return nil }
    let display = Unmanaged<NSObject>.fromOpaque(created).takeRetainedValue()

    let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
    guard let initModeIMP = class_getInstanceMethod(modeClass, initMode).map(method_getImplementation) else { return nil }
    let modes: [NSObject] = spec.modes.compactMap { mode in
      unsafeBitCast(initModeIMP, to: InitMode.self)(allocate(modeClass), initMode, mode.width, mode.height, mode.refreshRate)
        .map { Unmanaged<NSObject>.fromOpaque($0).takeRetainedValue() }
    }
    let settings = settingsClass.init()
    settings.setValue(NSNumber(value: spec.hiDPI ? 1 : 0), forKey: "hiDPI")
    settings.setValue(modes, forKey: "modes")

    let apply = NSSelectorFromString("applySettings:")
    guard display.responds(to: apply),
          unsafeBitCast(display.method(for: apply), to: ApplySettings.self)(display, apply, settings),
          let displayID = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value,
          displayID != 0 else { return nil }
    return (display, displayID)
  }

  /// `+alloc`, returned at +1 for an `-init…` call that consumes it.
  private static func allocate(_ type: NSObject.Type) -> UnsafeRawPointer {
    UnsafeRawPointer(type.perform(NSSelectorFromString("alloc"))!.toOpaque())
  }
}
