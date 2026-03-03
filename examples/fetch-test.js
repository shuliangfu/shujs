// 验证 fetch：需 --allow-net，使用返回明确 body 的真实接口
// httpbin.org/get 返回 JSON，便于检查 body 是否拿到
const r = fetch("https://httpbin.org/get");
console.log("ok:", r.ok, "status:", r.status);
console.log("body length:", r.body ? r.body.length : 0);
if (r.body && r.body.length > 0) {
  console.log(
    "body slice:",
    r.body.slice(0, 200) + (r.body.length > 200 ? "..." : ""),
  );
} else {
  console.log("body slice: (empty)");
}
