// 验证 process.env：需 --allow-env 才有内容
console.log("process.env.HOME:", process.env.HOME ?? "(undefined)");
console.log("process.env.PWD:", process.env.PWD ?? "(undefined)");
console.log("keys count:", Object.keys(process.env).length);
