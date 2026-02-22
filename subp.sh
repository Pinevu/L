# 覆盖更新拦截器脚本（零冗解重构版）
cat << 'EOF' > /root/snell_wrapper.py
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
import re

class ProxyHTTPRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        target_url = f"http://127.0.0.1:8000{self.path}"
        try:
            req = urllib.request.Request(target_url, headers={'User-Agent': 'Surge/1.0'})
            with urllib.request.urlopen(req) as response:
                content = response.read().decode('utf-8')
            
            lines = content.split('\n')
            proxy_mapping = {} # 存放 {旧名: 彻底净化的新名}
            clean_node_list = [] # 记录净化后的名字顺序
            new_lines = []
            current_section = ""

            for line in lines:
                l = line.strip()
                if not l or l.startswith('{{') or l.startswith('}}'): continue
                
                if l.startswith('['):
                    current_section = l.lower()
                    new_lines.append(line)
                    continue

                # --- 1. 处理 [Proxy] 段落 ---
                if current_section == '[proxy]' and '=' in l:
                    # 精准定位：找到真实的协议起始点 (ss, trojan, snell)
                    match = re.search(r'=\s*(ss|trojan|snell|vmess|vless)\s*,', l, re.I)
                    if match:
                        raw_name = l[:match.start()].strip()
                        raw_config = l[match.start()+1:].strip()
                        
                        # A. 彻底净化名字：去掉所有暗号 (=http, (obfs, (Snell 等)
                        # 甚至去掉结尾可能残存的等号
                        clean_name = re.sub(r'(\s*=\s*http|\s*[\(（].*)$', '', raw_name, flags=re.I).strip()
                        clean_name = clean_name.rstrip('= ').strip()
                        
                        # B. 彻底净化协议行：去掉行首可能残存的 "http =" 或其他脏字符
                        clean_config = re.sub(r'^(http|obfs|snell)\s*=\s*', '', raw_config, flags=re.I)
                        
                        # C. 逻辑转换
                        # Snell 转换
                        if 'snell' in l.lower() or 'snell' in raw_name.lower():
                            clean_config = clean_config.replace('trojan,', 'snell,').replace('password=', 'psk=')
                            clean_config = re.sub(r',? ?(sni|skip-cert-verify)=[^,]*', '', clean_config)
                            if 'version=' not in clean_config:
                                clean_config = clean_config.rstrip(', ') + ', version=4, reuse=true'
                        
                        # SS Obfs 补全
                        elif 'ss,' in clean_config.lower():
                            if 'obfs=' not in clean_config:
                                clean_config = clean_config.rstrip(', ') + ', obfs=http, obfs-host=iCloud.com'

                        proxy_mapping[raw_name] = clean_name
                        if clean_name not in clean_node_list:
                            clean_node_list.append(clean_name)
                        
                        new_lines.append(f"{clean_name} = {clean_config}")
                    else:
                        new_lines.append(l)

                # --- 2. 处理 [Proxy Group] 段落 ---
                elif current_section == '[proxy group]':
                    # 优先替换所有旧名字
                    fixed_line = l
                    for old, new in proxy_mapping.items():
                        fixed_line = fixed_line.replace(old, new)
                    
                    # 修复模板标签并填充真实节点
                    if '{{' in fixed_line:
                        node_str = ", ".join(clean_node_list)
                        fixed_line = re.sub(r'\{\{.*?\}\}.*?\{\{.*?\}\}', node_str, fixed_line)
                        fixed_line = re.sub(r'\{\{.*?\}\}', '', fixed_line)
                    
                    # 强力去重：防止出现重复名字
                    if '=' in fixed_line:
                        prefix, nodes = fixed_line.split('=', 1)
                        node_parts = [n.strip() for n in nodes.split(',')]
                        seen = set()
                        u_nodes = []
                        for n in node_parts:
                            if not n: continue
                            if n not in seen or n in ['select', 'url-test', 'Direct', 'Proxy']:
                                u_nodes.append(n)
                                if n not in ['select', 'url-test', 'Direct', 'Proxy']:
                                    seen.add(n)
                        fixed_line = f"{prefix}= {', '.join(u_nodes)}"
                    new_lines.append(fixed_line)

                # --- 3. 其他段落 (Rule 等) ---
                else:
                    fixed_line = l
                    for old, new in proxy_mapping.items():
                        fixed_line = fixed_line.replace(old, new)
                    new_lines.append(fixed_line)

            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write('\n'.join(new_lines).encode('utf-8'))
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"Error: {e}".encode('utf-8'))

HTTPServer(('0.0.0.0', 8001), ProxyHTTPRequestHandler).serve_forever()
EOF

systemctl restart snell-wrapper
echo "✅ 拦截器已升级为【零冗余净化版】！"
