/**
 * 单元测试工具：统一测试数据目录。
 * 所有需要读写文件的单元测试应使用本模块提供的目录，测试结束后统一清理。
 */
const path = require("shu:path");
const fs = require("shu:fs");

/** 项目内统一测试输出目录（所有测试的公共读写目录） */
const TEST_DATA_BASE = "tests/test-data";

/**
 * 返回统一测试数据目录的绝对路径。
 * @param {string} [subdir] - 子目录名（如 'fs'），不传则返回根目录
 * @returns {string} 绝对路径，不创建目录
 */
function getTestDataDir(subdir) {
  const base = path.join(process.cwd(), TEST_DATA_BASE);
  return subdir ? path.join(base, subdir) : base;
}

/**
 * 确保测试数据目录（及可选子目录）存在，不存在则递归创建。
 * @param {string} [subdir] - 子目录名（如 'fs'）
 * @returns {string} 目录绝对路径
 */
function ensureTestDataDir(subdir) {
  const dir = getTestDataDir(subdir);
  if (!fs.existsSync(dir)) {
    fs.mkdirRecursiveSync(dir);
  }
  return dir;
}

/**
 * 删除测试数据目录（或指定子目录）。若传 subdir 则只删该子目录，否则删除整个 tests/test-data。
 * @param {string} [subdir] - 子目录名（如 'fs'）；不传则删除根目录及全部内容
 */
function cleanupTestDataDir(subdir) {
  const dir = getTestDataDir(subdir);
  if (fs.existsSync(dir)) {
    fs.rmdirRecursiveSync(dir);
  }
}

module.exports = {
  getTestDataDir,
  ensureTestDataDir,
  cleanupTestDataDir,
};
