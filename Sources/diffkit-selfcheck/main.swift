import Foundation
@_spi(Testing) import DiffKit

// The checks are asserts, which -O compiles out. A release build would "pass" by checking nothing.
var assertsLive = false
assert({ assertsLive = true; return true }())
guard assertsLive else {
    FileHandle.standardError.write(Data("diffkit-selfcheck: asserts are compiled out; run a debug build (swift run diffkit-selfcheck)\n".utf8))
    exit(1)
}

DiffKitSelfTest.run()
print("DiffKit self-check passed")
