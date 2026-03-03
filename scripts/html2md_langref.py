#!/usr/bin/env python3
"""
将 Zig langref.html 转为 Markdown。
仅使用标准库，输出到项目根目录的 langref.md。
用法: python3 scripts/html2md_langref.py [path_to_langref.html]
"""

import re
import sys
import html
from pathlib import Path


def extract_main(html_text: str) -> str:
    """提取 #contents 或 body 主体内容，去掉 nav/header 等."""
    # Zig langref: <main id="contents">...</main>
    m = re.search(r'<main\s+id=["\']contents["\'][^>]*>(.*)</main>', html_text, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1)
    # 兼容：div id="contents"
    m = re.search(r'<div[^>]*id=["\']contents["\'][^>]*>(.*)</div>', html_text, re.DOTALL)
    if m:
        return m.group(1)
    # 否则取 body
    m = re.search(r'<body[^>]*>(.*)</body>', html_text, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1)
    return html_text


def html_to_markdown(html_content: str) -> str:
    """简单 HTML 转 Markdown：标题、代码块、链接、段落、实体."""
    s = html_content

    # 先保护 pre/code 块，避免被后续替换破坏
    code_blocks: list[str] = []
    def save_code(match):
        code_blocks.append(match.group(0))
        return f"\x00CODE{len(code_blocks)-1}\x00"

    s = re.sub(r'<pre[^>]*>\s*<code[^>]*>(.*?)</code>\s*</pre>', save_code, s, flags=re.DOTALL)
    s = re.sub(r'<pre[^>]*>\s*<samp[^>]*>(.*?)</samp>\s*</pre>', save_code, s, flags=re.DOTALL)
    s = re.sub(r'<pre[^>]*>(.*?)</pre>', save_code, s, flags=re.DOTALL)

    # figcaption 转为引用说明（代码块标题）
    s = re.sub(r'<figcaption[^>]*class="[^"]*zig-cap[^"]*"[^>]*>(.*?)</figcaption>', r'\n*Zig: \1*\n', s, flags=re.DOTALL)
    s = re.sub(r'<figcaption[^>]*>(.*?)</figcaption>', r'\n*\1*\n', s, flags=re.DOTALL)

    # 标题
    for level in range(6, 0, -1):
        tag = f'h{level}'
        prefix = '#' * level
        s = re.sub(rf'<{tag}(?:\s[^>]*)?>(.*?)</{tag}>', rf'\n\n{prefix} \1\n\n', s, flags=re.DOTALL | re.IGNORECASE)

    # 链接
    s = re.sub(r'<a\s+href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', r'[\2](\1)', s, flags=re.DOTALL | re.IGNORECASE)

    # 表格：简单处理 <tr><th>...</th></tr> 和 <tr><td>...</td></tr>
    def table_repl(match):
        table_html = match.group(0)
        rows = re.findall(r'<tr[^>]*>(.*?)</tr>', table_html, re.DOTALL | re.IGNORECASE)
        lines = []
        for i, row in enumerate(rows):
            cells = re.sub(r'<t[hd][^>]*>(.*?)</t[hd]>', r'\1', row, flags=re.DOTALL | re.IGNORECASE)
            cells = re.sub(r'<[^>]+>', ' ', cells)
            cells = ' | '.join(c.strip() for c in cells.split('|'))
            lines.append('| ' + cells + ' |')
            if i == 0 and '<th' in row.lower():
                ncol = len([c for c in cells.split('|') if c.strip()])
                lines.append('| ' + ' --- |' * max(ncol, 1))
        return '\n\n' + '\n'.join(lines) + '\n\n'
    s = re.sub(r'<table[^>]*>.*?</table>', table_repl, s, flags=re.DOTALL | re.IGNORECASE)

    # 列表
    s = re.sub(r'<li[^>]*>(.*?)</li>', r'- \1\n', s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r'</?ul>', '\n', s, flags=re.IGNORECASE)
    s = re.sub(r'</?ol>', '\n', s, flags=re.IGNORECASE)

    # dt/dd
    s = re.sub(r'<dt[^>]*>(.*?)</dt>', r'\n**\1**\n', s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r'<dd[^>]*>(.*?)</dd>', r'\1\n', s, flags=re.DOTALL | re.IGNORECASE)

    # 段落与换行
    s = re.sub(r'<p\s[^>]*>', '\n\n', s, flags=re.IGNORECASE)
    s = re.sub(r'</p>', '\n\n', s, flags=re.IGNORECASE)
    s = re.sub(r'<p>', '\n\n', s, flags=re.IGNORECASE)
    s = re.sub(r'<br\s*/?>', '\n', s, flags=re.IGNORECASE)

    # 行内：strong/b -> **, em/i -> *
    s = re.sub(r'<strong[^>]*>(.*?)</strong>', r'**\1**', s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r'<b[^>]*>(.*?)</b>', r'**\1**', s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r'<em[^>]*>(.*?)</em>', r'*\1*', s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r'<i[^>]*>(.*?)</i>', r'*\1*', s, flags=re.DOTALL | re.IGNORECASE)
    s = re.sub(r'<code[^>]*>(.*?)</code>', r'`\1`', s, flags=re.DOTALL | re.IGNORECASE)

    # 去掉所有剩余标签
    s = re.sub(r'<[^>]+>', '', s)

    # 恢复代码块
    for i, block in enumerate(code_blocks):
        # 从 block 中取出纯文本
        inner = re.sub(r'^<pre[^>]*>\s*<code[^>]*>', '', block, flags=re.IGNORECASE)
        inner = re.sub(r'</code>\s*</pre>$', '', inner, flags=re.IGNORECASE)
        inner = re.sub(r'^<pre[^>]*>', '', inner, flags=re.IGNORECASE)
        inner = re.sub(r'</pre>$', '', inner, flags=re.IGNORECASE)
        inner = re.sub(r'<[^>]+>', '', inner)
        inner = html.unescape(inner.strip())
        s = s.replace(f'\x00CODE{i}\x00', '\n\n```zig\n' + inner + '\n```\n\n', 1)

    # HTML 实体
    s = html.unescape(s)

    # 清理多余空行与首尾空白
    s = re.sub(r'\n{4,}', '\n\n\n', s)
    s = re.sub(r'[ \t]+\n', '\n', s)
    return s.strip() + '\n'


def main() -> None:
    if len(sys.argv) > 1:
        html_path = Path(sys.argv[1])
    else:
        # 默认：用户目录下的 zig 文档
        home = Path.home()
        html_path = home / ".zig" / "doc" / "langref.html"
        if not html_path.exists():
            html_path = home / ".zig" / "docs" / "langref.html"
    if not html_path.exists():
        print(f"Error: not found {html_path}", file=sys.stderr)
        sys.exit(1)

    root = Path(__file__).resolve().parent.parent
    out_path = root / "langref.md"

    html_text = html_path.read_text(encoding="utf-8", errors="replace")
    main_content = extract_main(html_text)
    md = html_to_markdown(main_content)

    # 加一个简短标题说明来源
    title = "# Zig Language Reference\n\nConverted from `langref.html` (Zig documentation).\n\n---\n\n"
    out_path.write_text(title + md, encoding="utf-8")
    print(f"Written: {out_path} ({len(md)} chars)")


if __name__ == "__main__":
    main()
