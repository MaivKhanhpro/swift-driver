//===--------------- Toolchain+LinkerSupport.swift - Swift Linker Support -===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic
import SwiftOptions

extension Toolchain {
  // MARK: - Path computation

  func computeResourceDirPath(
    for triple: Triple,
    parsedOptions: inout ParsedOptions,
    isShared: Bool
  ) throws -> AbsolutePath {
    // FIXME: This almost certainly won't be an absolute path in practice...
    let resourceDirBase: AbsolutePath
    if let resourceDir = parsedOptions.getLastArgument(.resourceDir) {
      resourceDirBase = try AbsolutePath(validating: resourceDir.asSingle)
    } else if !triple.isDarwin,
      let sdk = parsedOptions.getLastArgument(.sdk),
      let sdkPath = try? AbsolutePath(validating: sdk.asSingle) {
      resourceDirBase = sdkPath
        .appending(components: "usr", "lib",
                   isShared ? "swift" : "swift_static")
    } else {
      resourceDirBase = try getToolPath(.swiftCompiler)
        .parentDirectory // remove /swift
        .parentDirectory // remove /bin
        .appending(components: "lib", isShared ? "swift" : "swift_static")
    }
    return resourceDirBase.appending(components: triple.platformName() ?? "")
  }

  func computeSecondaryResourceDirPath(for triple: Triple, primaryPath: AbsolutePath) -> AbsolutePath? {
    guard triple.isMacCatalyst else { return nil }
    return primaryPath.parentDirectory.appending(component: "macosx")
  }

  func clangLibraryPath(
    for triple: Triple,
    parsedOptions: inout ParsedOptions
  ) throws -> AbsolutePath {
    return try computeResourceDirPath(for: triple,
                                      parsedOptions: &parsedOptions,
                                      isShared: true)
      .parentDirectory // Remove platform name.
      .appending(components: "clang", "lib",
                 triple.platformName(conflatingDarwin: true)!)
  }

  func runtimeLibraryPaths(
    for triple: Triple,
    parsedOptions: inout ParsedOptions,
    sdkPath: String?,
    isShared: Bool
  ) throws -> [AbsolutePath] {
    let resourceDirPath = try computeResourceDirPath(
      for: triple,
      parsedOptions: &parsedOptions,
      isShared: isShared)
    var result = [resourceDirPath]

    let secondaryResourceDir = computeSecondaryResourceDirPath(for: triple, primaryPath: resourceDirPath)
    if let path = secondaryResourceDir {
      result.append(path)
    }

    if let path = sdkPath {
      let sdkPath = AbsolutePath(path)
      // If we added the secondary resource dir, we also need the iOSSupport directory.
      if secondaryResourceDir != nil {
        result.append(sdkPath.appending(components: "System", "iOSSupport", "usr", "lib", "swift"))
      }

      result.append(sdkPath.appending(RelativePath("usr/lib/swift")))
    }

    return result
  }

  func addLinkRuntimeLibrary(
    named name: String,
    to commandLine: inout [Job.ArgTemplate],
    for triple: Triple,
    parsedOptions: inout ParsedOptions
  ) throws {
    let path = try clangLibraryPath(
      for: triple,
      parsedOptions: &parsedOptions)
      .appending(component: name)
    commandLine.appendPath(path)
  }

  func runtimeLibraryExists(
    for sanitizer: Sanitizer,
    targetTriple: Triple,
    parsedOptions: inout ParsedOptions,
    isShared: Bool
  ) throws -> Bool {
    let runtimeName = try runtimeLibraryName(
      for: sanitizer,
      targetTriple: targetTriple,
      isShared: isShared
    )
    let path = try clangLibraryPath(
      for: targetTriple,
      parsedOptions: &parsedOptions
    ).appending(component: runtimeName)
    return fileSystem.exists(path)
  }
}

// MARK: - Common argument routines

extension DarwinToolchain {
  func getSwiftRuntimeCompatibilityVersion(for targetTriple: Triple) -> (Int, Int)? {
    // FIXME: Add arm64e to Triple.swift
    if targetTriple.archName == "arm64e" {
      return (5, 3)
    }

    if targetTriple.isMacOSX {
      let macOSVersion = targetTriple.version(for: .macOS)
      switch (macOSVersion.major, macOSVersion.minor, macOSVersion.micro) {
      case (10, ...14, _):
        return (5, 0)
      case (10, ...15, ...3):
        return (5, 1)
      case (10, ...15, _):
        return (5, 2)
      default:
        break
      }
    } else if targetTriple.isiOS { // includes tvOS
      let iOSVersion = targetTriple.version(for: .iOS(.device))
      switch (iOSVersion.major, iOSVersion.minor, iOSVersion.micro) {
      case (...12, _, _):
        return (5, 0)
      case (13, ...3, _):
        return (5, 1)
      case (13, _, _):
        return (5, 2)
      default:
        break
      }
    } else if targetTriple.isWatchOS {
      let watchOSVersion = targetTriple.version(for: .watchOS(.device))
      switch (watchOSVersion.major, watchOSVersion.minor, watchOSVersion.micro) {
      case (...5, _, _):
        return (5, 0)
      case (6, ...1, _):
        return (5, 1)
      case (6, _, _):
        return (5, 2)
      default:
        break
      }
    }
    return nil
  }

  func addArgsToLinkStdlib(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    sdkPath: String?,
    targetTriple: Triple,
    linkerOutputType: LinkOutputType,
    fileSystem: FileSystem
  ) throws {
    // Link compatibility libraries, if we're deploying back to OSes that
    // have an older Swift runtime.
    var runtimeCompatibilityVersion: (Int, Int)? = nil
    let resourceDirPath = try computeResourceDirPath(for: targetTriple,
                                                     parsedOptions: &parsedOptions,
                                                     isShared: true)
    if let version = parsedOptions.getLastArgument(.runtimeCompatibilityVersion)?.asSingle {
      switch version {
      case "5.0":
        runtimeCompatibilityVersion = (5, 0)
      case "5.1":
        runtimeCompatibilityVersion = (5, 1)
      case "none":
        runtimeCompatibilityVersion = nil
      default:
        // TODO: diagnose unknown runtime compatibility version?
        break
      }
    } else if linkerOutputType == .executable {
      runtimeCompatibilityVersion = getSwiftRuntimeCompatibilityVersion(for: targetTriple)
    }

    func addArgsForBackDeployLib(_ libName: String) {
      let backDeployLibPath = resourceDirPath.appending(component: libName)
      if fileSystem.exists(backDeployLibPath) {
        commandLine.append(.flag("-force_load"))
        commandLine.appendPath(backDeployLibPath)
      }
    }

    if let compatibilityVersion = runtimeCompatibilityVersion {
      if compatibilityVersion <= (5, 0) {
        // Swift 5.0 compatibility library
        addArgsForBackDeployLib("libswiftCompatibility50.a")
      }

      if compatibilityVersion <= (5, 1) {
        // Swift 5.1 compatibility library
        addArgsForBackDeployLib("libswiftCompatibility51.a")
      }

      if linkerOutputType == .executable && compatibilityVersion <= (5, 0) {
        // Swift 5.0 dynamic replacement compatibility library.
        addArgsForBackDeployLib("libswiftCompatibilityDynamicReplacements.a")
      }
    }

    // Add the runtime library link path, which is platform-specific and found
    // relative to the compiler.
    let runtimePaths = try runtimeLibraryPaths(
      for: targetTriple,
      parsedOptions: &parsedOptions,
      sdkPath: sdkPath,
      isShared: true
    )
    for path in runtimePaths {
      commandLine.appendFlag(.L)
      commandLine.appendPath(path)
    }

    let rpaths = StdlibRpathRule(
      parsedOptions: &parsedOptions,
      targetTriple: targetTriple
    )
    for path in rpaths.paths(runtimeLibraryPaths: runtimePaths) {
      commandLine.appendFlag("-rpath")
      commandLine.appendPath(path)
    }
  }

  /// Represents the rpaths we need to add in order to find the
  /// desired standard library at runtime.
  fileprivate enum StdlibRpathRule {
    /// Add a set of rpaths that will allow the compiler resource directory
    /// to override Swift-in-the-OS dylibs.
    case toolchain

    /// Add an rpath that will search Swift-in-the-OS dylibs, but not
    /// compiler resource directory dylibs.
    case os

    /// Do not add any rpaths at all.
    case none

    /// Determines the appropriate rule for the
    init(parsedOptions: inout ParsedOptions, targetTriple: Triple) {
      if parsedOptions.hasFlag(
        positive: .toolchainStdlibRpath,
        negative: .noToolchainStdlibRpath,
        default: false
        ) {
        // If the user has explicitly asked for a toolchain stdlib, we should
        // provide one using -rpath. This used to be the default behaviour but it
        // was considered annoying in at least the SwiftPM scenario (see
        // https://bugs.swift.org/browse/SR-1967) and is obsolete in all scenarios
        // of deploying for Swift-in-the-OS. We keep it here as an optional
        // behaviour so that people downloading snapshot toolchains for testing new
        // stdlibs will be able to link to the stdlib bundled in that toolchain.
        self = .toolchain
      }
      else if targetTriple.supports(.swiftInTheOS) ||
        parsedOptions.hasArgument(.noStdlibRpath) {
        // If targeting an OS with Swift in /usr/lib/swift, the LC_ID_DYLIB
        // install_name the stdlib will be an absolute path like
        // /usr/lib/swift/libswiftCore.dylib, and we do not need to provide an rpath
        // at all.
        //
        // Also, if the user explicitly asks for no rpath entry, we assume they know
        // what they're doing and do not add one here.
        self = .none
      }
      else {
        // The remaining cases are back-deploying (to OSs predating
        // Swift-in-the-OS). In these cases, the stdlib will be giving us (via
        // stdlib/linker-support/magic-symbols-for-install-name.c) an LC_ID_DYLIB
        // install_name that is rpath-relative, like @rpath/libswiftCore.dylib.
        //
        // If we're linking an app bundle, it's possible there's an embedded stdlib
        // in there, in which case we'd want to put @executable_path/../Frameworks
        // in the rpath to find and prefer it, but (a) we don't know when we're
        // linking an app bundle and (b) we probably _never_ will be because Xcode
        // links using clang, not the swift driver.
        //
        // So that leaves us with the case of linking a command-line app. These are
        // only supported by installing a secondary package that puts some frozen
        // Swift-in-OS libraries in the /usr/lib/swift location. That's the best we
        // can give for rpath, though it might fail at runtime if the support
        // package isn't installed.
        self = .os
      }
    }

    func paths(runtimeLibraryPaths: [AbsolutePath]) -> [AbsolutePath] {
      switch self {
      case .toolchain:
        return runtimeLibraryPaths
      case .os:
        return [AbsolutePath("/usr/lib/swift")]
      case .none:
        return []
      }
    }
  }

}
