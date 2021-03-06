//===--------------- Toolchain.swift - Swift Toolchain Abstraction --------===//
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
import Foundation
import TSCBasic
import SwiftOptions

public enum Tool {
  case swiftCompiler
  case staticLinker
  case dynamicLinker
  case clang
  case swiftAutolinkExtract
  case dsymutil
  case lldb
  case dwarfdump
  case swiftHelp
}

/// Describes information about the target as provided by the Swift frontend.
struct FrontendTargetInfo: Codable {
  struct Target: Codable {
    /// The target triple
    let triple: Triple

    /// The target triple without any version information.
    let unversionedTriple: Triple

    /// The triple used for module names.
    let moduleTriple: Triple

    /// Whether the Swift libraries need to be referenced in their system
    /// location (/usr/lib/swift) via rpath .
    let librariesRequireRPath: Bool
  }

  struct Paths: Codable {
    let runtimeLibraryPaths: [String]
    let runtimeLibraryImportPaths: [String]
    let runtimeResourcePath: String
  }

  let target: Target
  let targetVariant: Target?
}

/// Describes a toolchain, which includes information about compilers, linkers
/// and other tools required to build Swift code.
public protocol Toolchain {
  init(env: [String: String], fileSystem: FileSystem)

  var env: [String: String] { get }

  var fileSystem: FileSystem { get }

  var searchPaths: [AbsolutePath] { get }

  /// Retrieve the absolute path to a particular tool.
  func getToolPath(_ tool: Tool) throws -> AbsolutePath

  /// Set an absolute path to be used for a particular tool.
  func overrideToolPath(_ tool: Tool, path: AbsolutePath)

  /// Returns path of the default SDK, if there is one.
  func defaultSDKPath() throws -> AbsolutePath?

  /// When the compiler invocation should be stored in debug information.
  var shouldStoreInvocationInDebugInfo: Bool { get }

  /// Constructs a proper output file name for a linker product.
  func makeLinkerOutputFilename(moduleName: String, type: LinkOutputType) -> String

  /// Adds platform-specific linker flags to the provided command line
  func addPlatformSpecificLinkerArgs(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    linkerOutputType: LinkOutputType,
    inputs: [TypedVirtualPath],
    outputFile: VirtualPath,
    sdkPath: String?,
    sanitizers: Set<Sanitizer>,
    targetTriple: Triple,
    targetVariantTriple: Triple?
  ) throws -> AbsolutePath

  func runtimeLibraryName(
    for sanitizer: Sanitizer,
    targetTriple: Triple,
    isShared: Bool
  ) throws -> String

  func platformSpecificInterpreterEnvironmentVariables(
    env: [String: String],
    parsedOptions: inout ParsedOptions,
    sdkPath: String?,
    targetTriple: Triple) throws -> [String: String]
}

extension Toolchain {
  public var searchPaths: [AbsolutePath] {
    getEnvSearchPaths(pathString: env["PATH"], currentWorkingDirectory: fileSystem.currentWorkingDirectory)
  }

  public func swiftCompilerVersion() throws -> String {
    try Process.checkNonZeroExit(
      args: getToolPath(.swiftCompiler).pathString, "-version",
      environment: env
    ).split(separator: "\n").first.map(String.init) ?? ""
  }

  /// Retrieve information about the target from
  func getFrontendTargetInfo(target: Triple?, targetVariant: Triple?) throws
      -> FrontendTargetInfo {
    // Print information for the given target.
    var args = [
      try getToolPath(.swiftCompiler).pathString,
      "-print-target-info",
    ]

    // If we were given a target, include it. Otherwise, let the frontend
    // tell us the host target.
    if let target = target {
      args += [
        "-target", target.triple
      ]
    }

    // If there is a target variant, include that too.
    if let targetVariant = targetVariant {
      args += [
        "-target-variant",
        targetVariant.triple
      ]
    }

    let resultString = try Process.checkNonZeroExit(arguments: args)
    guard let resultData = resultString.data(using: .utf8) else {
      throw Driver.Error.malformedSwiftTargetInfo(resultString)
    }
    return try JSONDecoder().decode(FrontendTargetInfo.self, from: resultData)
  }

  /// Returns the target triple string for the current host.
  public func hostTargetTriple() throws -> Triple {
    return try getFrontendTargetInfo(target: nil, targetVariant: nil)
      .target.triple
  }

  /// Returns the `executablePath`'s directory.
  public var executableDir: AbsolutePath {
    guard let path = Bundle.main.executablePath else {
      fatalError("Could not find executable path.")
    }
    return AbsolutePath(path).parentDirectory
  }

  /// Looks for `SWIFT_DRIVER_TOOLNAME_EXEC` in the `env` property.
  /// - Returns: Environment variable value, if any.
  func envVar(forExecutable toolName: String) -> String? {
    return env[envVarName(for: toolName)]
  }

  /// - Returns: String in the form of: `SWIFT_DRIVER_TOOLNAME_EXEC`
  private func envVarName(for toolName: String) -> String {
    let lookupName = toolName
      .replacingOccurrences(of: "-", with: "_")
      .uppercased()
    return "SWIFT_DRIVER_\(lookupName)_EXEC"
  }

  /// Use this property only for testing purposes, for example,
  /// to enable cross-compiling tests that depends on macOS tooling such as `dsymutil`.
  ///
  /// Returns true if `SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK` is set to `1`.
  private var fallbackToExecutableDefaultPath: Bool {
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] == "1"
  }

  /// Looks for the executable in the `SWIFT_DRIVER_TOOLNAME_EXEC` environment variable, if found nothing,
  /// looks in the `executableDir`, `xcrunFind` or in the `searchPaths`.
  /// - Parameter executable: executable to look for [i.e. `swift`].
  func lookup(executable: String) throws -> AbsolutePath {
    if let overrideString = envVar(forExecutable: executable) {
      return try AbsolutePath(validating: overrideString)
    } else if let path = lookupExecutablePath(filename: executable, searchPaths: [executableDir]) {
      return path
    } else if let path = try? xcrunFind(executable: executable) {
      return path
    } else if let path = lookupExecutablePath(filename: executable, searchPaths: searchPaths) {
      return path
    } else if executable == "swift-frontend" {
      // Temporary shim: fall back to looking for "swift" before failing.
      return try lookup(executable: "swift")
    } else if fallbackToExecutableDefaultPath {
      return AbsolutePath("/usr/bin/" + executable)
    } else {
      throw ToolchainError.unableToFind(tool: executable)
    }
  }

  private func xcrunFind(executable: String) throws -> AbsolutePath {
    let xcrun = "xcrun"
    guard lookupExecutablePath(filename: xcrun, searchPaths: searchPaths) != nil else {
      throw ToolchainError.unableToFind(tool: xcrun)
    }

    let path = try Process.checkNonZeroExit(
      arguments: [xcrun, "--find", executable],
      environment: env
    ).spm_chomp()
    return AbsolutePath(path)
  }
}

public enum ToolchainError: Swift.Error {
  case unableToFind(tool: String)
}
