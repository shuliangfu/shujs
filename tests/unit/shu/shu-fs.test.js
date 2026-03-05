// shu:fs 模块测试（readSync/writeSync/existsSync/readdirSync 等）
// 约定：读写统一使用 tests/unit/utils 提供的测试数据目录，用例结束后清理。
const { describe, it, assert, beforeAll, afterAll } = require("shu:test");
const path = require("shu:path");
const fs = require("shu:fs");
const { getTestDataDir, ensureTestDataDir, cleanupTestDataDir } = require("../utils.js");

/** 同步方法名（与 fs attachMethods 一致，用于存在性检查） */
const SYNC_NAMES = [
  "readSync", "writeSync", "readdirSync", "mkdirSync", "existsSync", "statSync",
  "realpathSync", "lstatSync", "truncateSync", "accessSync", "isEmptyDirSync", "sizeSync",
  "isFileSync", "isDirectorySync", "readdirWithStatsSync", "ensureFileSync",
  "unlinkSync", "rmdirSync", "renameSync", "copySync", "appendSync",
  "symlinkSync", "readlinkSync", "mkdirRecursiveSync", "rmdirRecursiveSync", "ensureDirSync",
  "readFileSync", "writeFileSync", "copyFileSync", "appendFileSync",
];

/** 异步方法名（至少存在） */
const ASYNC_NAMES = [
  "read", "write", "readdir", "mkdir", "exists", "stat", "realpath", "lstat", "truncate",
  "access", "isEmptyDir", "size", "isFile", "isDirectory", "readdirWithStats", "ensureFile",
  "unlink", "rmdir", "rename", "copy", "append", "symlink", "readlink", "mkdirRecursive", "rmdirRecursive",
];

describe("shu:fs", () => {
  beforeAll(() => {
    ensureTestDataDir("fs");
  });

  afterAll(() => {
    cleanupTestDataDir("fs");
  });

  it("has all sync and node-compat method names", () => {
    for (const name of SYNC_NAMES) {
      assert.strictEqual(typeof fs[name], "function", "fs." + name);
    }
  });

  it("has async method names", () => {
    for (const name of ASYNC_NAMES) {
      assert.strictEqual(typeof fs[name], "function", "fs." + name);
    }
  });

  it("existsSync(process.cwd()) is true", () => {
    assert.strictEqual(fs.existsSync(process.cwd()), true);
  });

  it("writeSync then readSync roundtrip", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "writeSync-readSync-" + Date.now() + ".txt");
    const content = "hello shu fs";
    fs.writeSync(file, content);
    const read = fs.readSync(file);
    assert.strictEqual(read, content);
    fs.unlinkSync(file);
  });

  it("has mkdirSync, statSync, unlinkSync", () => {
    assert.strictEqual(typeof fs.mkdirSync, "function");
    assert.strictEqual(typeof fs.statSync, "function");
    assert.strictEqual(typeof fs.unlinkSync, "function");
  });

  it("readFileSync/writeFileSync node compat roundtrip", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "readFile-writeFile-" + Date.now() + ".txt");
    const content = "node compat";
    fs.writeFileSync(file, content);
    assert.strictEqual(fs.readFileSync(file), content);
    fs.unlinkSync(file);
  });

  it("mkdirSync and readdirSync list created dir", () => {
    const dir = getTestDataDir("fs");
    const subdir = path.join(dir, "subdir-" + Date.now());
    fs.mkdirSync(subdir);
    assert.strictEqual(fs.existsSync(subdir), true);
    const names = fs.readdirSync(subdir);
    assert.ok(Array.isArray(names) && names.length === 0);
    fs.rmdirSync(subdir);
  });

  it("statSync returns stats for file", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "stat-target-" + Date.now() + ".txt");
    fs.writeFileSync(file, "x");
    const st = fs.statSync(file);
    assert.ok(st && typeof st.size === "number" && st.size >= 0);
    assert.strictEqual(fs.isFileSync(file), true);
    fs.unlinkSync(file);
  });

  it("appendSync / appendFileSync append to file", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "append-" + Date.now() + ".txt");
    fs.writeSync(file, "a");
    fs.appendSync(file, "b");
    fs.appendFileSync(file, "c");
    assert.strictEqual(fs.readSync(file), "abc");
    fs.unlinkSync(file);
  });

  it("renameSync moves file", () => {
    const dir = getTestDataDir("fs");
    const from = path.join(dir, "rename-from-" + Date.now() + ".txt");
    const to = path.join(dir, "rename-to-" + Date.now() + ".txt");
    fs.writeFileSync(from, "renamed");
    fs.renameSync(from, to);
    assert.strictEqual(fs.existsSync(from), false);
    assert.strictEqual(fs.readFileSync(to), "renamed");
    fs.unlinkSync(to);
  });

  it("copySync / copyFileSync copies file", () => {
    const dir = getTestDataDir("fs");
    const src = path.join(dir, "copy-src-" + Date.now() + ".txt");
    const dest = path.join(dir, "copy-dest-" + Date.now() + ".txt");
    fs.writeFileSync(src, "copy content");
    fs.copySync(src, dest);
    assert.strictEqual(fs.readFileSync(dest), "copy content");
    fs.copyFileSync(src, dest);
    assert.strictEqual(fs.readFileSync(dest), "copy content");
    fs.unlinkSync(src);
    fs.unlinkSync(dest);
  });

  it("truncateSync truncates file", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "truncate-" + Date.now() + ".txt");
    fs.writeFileSync(file, "hello");
    fs.truncateSync(file, 2);
    assert.strictEqual(fs.readSync(file), "he");
    fs.unlinkSync(file);
  });

  it("realpathSync resolves path", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "realpath-" + Date.now() + ".txt");
    fs.writeFileSync(file, "x");
    const resolved = fs.realpathSync(file);
    assert.ok(typeof resolved === "string" && resolved.length > 0);
    assert.strictEqual(fs.readSync(resolved), "x");
    fs.unlinkSync(file);
  });

  it("mkdirRecursiveSync and rmdirRecursiveSync", () => {
    const dir = getTestDataDir("fs");
    const deep = path.join(dir, "a", "b", "c");
    fs.mkdirRecursiveSync(deep);
    const file = path.join(deep, "f.txt");
    fs.writeFileSync(file, "x");
    assert.strictEqual(fs.existsSync(deep), true);
    assert.strictEqual(fs.isDirectorySync(deep), true);
    fs.unlinkSync(file);
    fs.rmdirRecursiveSync(path.join(dir, "a"));
    assert.strictEqual(fs.existsSync(deep), false);
  });

  it("ensureFileSync creates empty file", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "ensure-file-" + Date.now() + ".txt");
    fs.ensureFileSync(file);
    assert.strictEqual(fs.existsSync(file), true);
    assert.strictEqual(fs.isFileSync(file), true);
    assert.strictEqual(fs.readSync(file), "");
    fs.unlinkSync(file);
  });

  it("ensureDirSync creates path recursively", () => {
    const dir = getTestDataDir("fs");
    const deep = path.join(dir, "ensure-d", "e", "f");
    fs.ensureDirSync(deep);
    assert.strictEqual(fs.existsSync(deep), true);
    assert.strictEqual(fs.isDirectorySync(deep), true);
    fs.rmdirRecursiveSync(path.join(dir, "ensure-d"));
  });

  it("isEmptyDirSync and sizeSync", () => {
    const dir = getTestDataDir("fs");
    const emptySub = path.join(dir, "empty-" + Date.now());
    fs.mkdirSync(emptySub);
    assert.strictEqual(fs.isEmptyDirSync(emptySub), true);
    const file = path.join(dir, "size-" + Date.now() + ".txt");
    const content = "12345";
    fs.writeFileSync(file, content);
    assert.strictEqual(fs.sizeSync(file), content.length);
    fs.writeFileSync(path.join(emptySub, "x"), "x");
    assert.strictEqual(fs.isEmptyDirSync(emptySub), false);
    fs.unlinkSync(path.join(emptySub, "x"));
    fs.rmdirSync(emptySub);
    fs.unlinkSync(file);
  });

  it("readdirWithStatsSync returns names and stats", () => {
    const dir = getTestDataDir("fs");
    const sub = path.join(dir, "withstats-" + Date.now());
    fs.mkdirSync(sub);
    const f = path.join(sub, "f.txt");
    fs.writeFileSync(f, "x");
    const entries = fs.readdirWithStatsSync(sub);
    assert.ok(Array.isArray(entries) && entries.length === 1);
    assert.strictEqual(entries[0].name, "f.txt");
    assert.ok(typeof entries[0].isFile === "boolean");
    fs.unlinkSync(f);
    fs.rmdirSync(sub);
  });

  it("accessSync on existing file", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "access-" + Date.now() + ".txt");
    fs.writeFileSync(file, "x");
    fs.accessSync(file);
    fs.unlinkSync(file);
  });

  it("symlinkSync and readlinkSync", () => {
    const dir = getTestDataDir("fs");
    const target = path.join(dir, "sym-target-" + Date.now() + ".txt");
    const linkPath = path.join(dir, "sym-link-" + Date.now());
    fs.writeFileSync(target, "target");
    fs.symlinkSync(target, linkPath);
    const out = fs.readlinkSync(linkPath);
    assert.ok(typeof out === "string");
    assert.strictEqual(fs.readSync(linkPath), "target");
    fs.unlinkSync(linkPath);
    fs.unlinkSync(target);
  });

  it("lstatSync on file has isSymbolicLink", () => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "lstat-" + Date.now() + ".txt");
    fs.writeFileSync(file, "x");
    const st = fs.lstatSync(file);
    assert.ok(st && typeof st.isSymbolicLink === "boolean");
    fs.unlinkSync(file);
  });

  // 边界：不存在路径（使用统一目录下的不存在的文件名，不污染 cwd）
  it("boundary: existsSync(nonExistent) is false", () => {
    const dir = getTestDataDir("fs");
    const nonExistent = path.join(dir, "nonexistent-" + Date.now());
    assert.strictEqual(fs.existsSync(nonExistent), false);
  });

  it("boundary: readSync(nonExistent) throws", () => {
    const dir = getTestDataDir("fs");
    const nonExistent = path.join(dir, "nonexistent-read-" + Date.now());
    assert.throws(() => fs.readSync(nonExistent));
  });

  it("boundary: statSync(nonExistent) throws", () => {
    const dir = getTestDataDir("fs");
    const nonExistent = path.join(dir, "nonexistent-stat-" + Date.now());
    assert.throws(() => fs.statSync(nonExistent));
  });

  it("boundary: readdirSync(nonExistent) throws", () => {
    const dir = getTestDataDir("fs");
    const nonExistent = path.join(dir, "nonexistent-dir-" + Date.now());
    assert.throws(() => fs.readdirSync(nonExistent));
  });

  it("boundary: writeSync with empty buffer does not throw", () => {
    const dir = getTestDataDir("fs");
    ensureTestDataDir("fs");
    const f = path.join(dir, "empty-write-" + Date.now());
    fs.writeFileSync(f, "");
    assert.strictEqual(fs.readFileSync(f, "utf8"), "");
    fs.unlinkSync(f);
  });

  it("boundary: readFileSync with encoding returns string", () => {
    const dir = getTestDataDir("fs");
    ensureTestDataDir("fs");
    const f = path.join(dir, "enc-" + Date.now());
    fs.writeFileSync(f, "utf8-content", "utf8");
    const s = fs.readFileSync(f, "utf8");
    assert.strictEqual(typeof s, "string");
    assert.strictEqual(s, "utf8-content");
    fs.unlinkSync(f);
  });

  it("exists(path, callback) async real call", (done) => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "async-exists-" + Date.now());
    fs.writeFileSync(file, "x");
    fs.exists(file, (exists) => {
      assert.strictEqual(exists, true);
      fs.unlinkSync(file);
      fs.exists(path.join(dir, "nonexistent-" + Date.now()), (e2) => {
        assert.strictEqual(e2, false);
        done();
      });
    });
  });

  it("readFile(path, callback) async roundtrip", (done) => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "async-read-" + Date.now());
    const content = "async-read-content";
    fs.writeFileSync(file, content);
    fs.readFile(file, (err, data) => {
      assert.ok(err === null || err === undefined);
      assert.ok(data != null);
      assert.strictEqual(String(data), content);
      fs.unlinkSync(file);
      done();
    });
  });

  it("writeFile(path, data, callback) then readFileSync", (done) => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "async-write-" + Date.now());
    fs.writeFile(file, "async-write-body", (err) => {
      assert.ok(err === null || err === undefined);
      assert.strictEqual(fs.readFileSync(file), "async-write-body");
      fs.unlinkSync(file);
      done();
    });
  });

  it("stat(path, callback) async returns stats", (done) => {
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "async-stat-" + Date.now());
    fs.writeFileSync(file, "x");
    fs.stat(file, (err, st) => {
      assert.ok(err === null || err === undefined);
      assert.ok(st && typeof st.size === "number");
      fs.unlinkSync(file);
      done();
    });
  });

  it("boundary: unlinkSync(nonExistent) throws or no-op", () => {
    const dir = getTestDataDir("fs");
    const nonExistent = path.join(dir, "nonexistent-unlink-" + Date.now());
    try {
      fs.unlinkSync(nonExistent);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("boundary: realpathSync(nonExistent) throws", () => {
    const dir = getTestDataDir("fs");
    const nonExistent = path.join(dir, "nonexistent-realpath-" + Date.now());
    assert.throws(() => fs.realpathSync(nonExistent));
  });

  // ---------- fs.watch：需 --allow-read，事件由主线程 drain 回调 listener(eventType, filename) ----------
  describe("fs.watch", () => {
    it("watch: returns watcher with close method", () => {
      const dir = getTestDataDir("fs");
      const watcher = fs.watch(dir, () => {});
      assert.ok(watcher != null && typeof watcher === "object");
      assert.strictEqual(typeof watcher.close, "function");
      watcher.close();
    });

    it("watch: receives event when file is written in watched dir", (done) => {
      const dir = getTestDataDir("fs");
      const name = "watch-change-" + Date.now() + ".txt";
      const events = [];
      const watcher = fs.watch(dir, (eventType, filename) => {
        events.push({ eventType, filename: filename || "" });
      });
      fs.writeFileSync(path.join(dir, name), "x");
      // 多轮 setImmediate 让事件循环执行 drain_fs_watch，平台可能上报 change 或 rename
      function pump(n) {
        setImmediate(() => {
          if (n <= 0) {
            watcher.close();
            assert.ok(events.length >= 1, "expected at least one watch event, got " + events.length);
            assert.ok(
              events.some((e) => e.eventType === "change" || e.eventType === "rename"),
              "expected eventType change or rename, got " + JSON.stringify(events)
            );
            try { fs.unlinkSync(path.join(dir, name)); } catch (_) {}
            done();
            return;
          }
          pump(n - 1);
        });
      }
      pump(5);
    }, { timeout: 3000 });

    it("watch: close() stops watcher", (done) => {
      const dir = getTestDataDir("fs");
      const name = "watch-close-" + Date.now() + ".txt";
      let afterClose = 0;
      const watcher = fs.watch(dir, () => { afterClose++; });
      watcher.close();
      fs.writeFileSync(path.join(dir, name), "y");
      setImmediate(() => {
        setImmediate(() => {
          try { fs.unlinkSync(path.join(dir, name)); } catch (_) {}
          assert.strictEqual(afterClose, 0, "listener should not run after close");
          done();
        });
      });
    }, { timeout: 2000 });
  });
});
