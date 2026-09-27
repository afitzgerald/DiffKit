// Real `git diff` output (git 2.55.0), captured from a scratch repo. Tabs are written as
// \#t so an editor cannot strip the trailing ones git puts after a path with a space.
let sampleDiff = #"""
diff --git a/Sources/App/Download.swift b/Sources/App/Download.swift
index bf617cf..6a0a5cf 100644
--- a/Sources/App/Download.swift
+++ b/Sources/App/Download.swift
@@ -1,22 +1,23 @@
 import Foundation
 
-/// A file being downloaded.
-struct Download: Identifiable {
+/// A file being downloaded, with its progress on disk.
+struct Download: Identifiable, Hashable {
     let id: UUID
     var name: String
     var url: URL
+    var destination: URL
     var isPaused = false
 
     /* Multi-line comment
        describing the timeout. */
-    static let timeout: TimeInterval = 30
+    static let timeout: TimeInterval = 45
 
     func label() -> String {
-        return "\(name) (\(url.host ?? "?"))"
+        return "\(name) [\(url.host ?? "?")]"
     }
 
-    mutating func resume(from offset: Int) {
+    mutating func resume(from offset: Int, retries: Int = 3) {
         isPaused = false
-        print("resuming at", offset)
+        print("resuming at", offset, "retries:", retries, "destination:", destination.path, "url:", url.absoluteString, "name:", name, "id:", id.uuidString)
     }
 }
diff --git a/docs notes.md b/docs notes.md
deleted file mode 100644
index 7a0f8f6..0000000
--- a/docs notes.md\#t
+++ /dev/null
@@ -1,3 +0,0 @@
-# Notes
-
-Old intro line.
diff --git a/docs/release notes.md b/docs/release notes.md
new file mode 100644
index 0000000..6a2b8e9
--- /dev/null
+++ b/docs/release notes.md\#t
@@ -0,0 +1,3 @@
+# Notes
+
+New intro line.
diff --git a/icon.png b/icon.png
index f584f40..6bf43ff 100644
Binary files a/icon.png and b/icon.png differ
diff --git a/legacy.txt b/legacy.txt
deleted file mode 100644
index da9ee9d..0000000
--- a/legacy.txt
+++ /dev/null
@@ -1 +0,0 @@
-legacy
diff --git a/package.json b/package.json
index 2d7d546..9481f31 100644
--- a/package.json
+++ b/package.json
@@ -1,5 +1,5 @@
 {
   "name": "example",
-  "version": "0.1.0",
+  "version": "0.2.0",
   "private": true
-}
+}
\ No newline at end of file
diff --git a/scripts/sync.py b/scripts/sync.py
old mode 100644
new mode 100755
index 401281a..83f43af
--- a/scripts/sync.py
+++ b/scripts/sync.py
@@ -3,8 +3,10 @@ import sys
 
 def sync(paths, dry_run=False):
     for p in paths:
-        print(f"syncing {p}")
+        if dry_run:
+            continue
+        print(f"syncing {p!r}")
     return len(paths)
 
 if __name__ == "__main__":
-    sync(sys.argv[1:])
+    sync(sys.argv[1:], dry_run="-n" in sys.argv)
diff --cc conflicted.txt
index af70335,f794161..0000000
--- a/conflicted.txt
+++ b/conflicted.txt
@@@ -1,3 -1,3 +1,7 @@@
  a
++<<<<<<< HEAD
 +MAIN
++=======
+ SIDE
++>>>>>>> side
  c
diff --git a/link b/link
deleted file mode 100644
index db55786..0000000
--- a/link
+++ /dev/null
@@ -1,3 +0,0 @@
-main-g
-keep
-side-g
diff --git a/link b/link
new file mode 120000
index 0000000..7f66e4f
--- /dev/null
+++ b/link
@@ -0,0 +1 @@
+f.txt
\ No newline at end of file
"""#
