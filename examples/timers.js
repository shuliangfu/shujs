// 验证 setTimeout / setInterval
console.log("start");
setTimeout(function () {
  console.log("timeout 50ms");
}, 50);
var n = 0;
var id = setInterval(function () {
  n++;
  console.log("interval", n);
  if (n >= 2) clearInterval(id);
}, 30);
console.log("end");
