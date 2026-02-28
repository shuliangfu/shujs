// 测试 Shu.file.read：需 --allow-read
var content = Shu.file.read("examples/hello.js");
console.log("read length:", content ? content.length : 0);
if (content) console.log("first line:", content.split("\n")[0]);
