from pathlib import Path
from urllib.parse import urlsplit
from html import escape
import sys,re
base=sys.argv[1].rstrip('/')
url=urlsplit(base)
if url.scheme!='https' or not url.netloc or url.query or url.fragment:
    raise SystemExit('Use the real https:// public website URL (including any project subfolder).')
root=Path(__file__).resolve().parent
for name in ['index.html','test0.html']:
    p=root/name;s=p.read_text()
    s=re.sub(r'<link rel="canonical"[^>]*>\s*','',s)
    s=s.replace('</head>','<link rel="canonical" href="'+escape(base+'/',quote=True)+'">\n</head>')
    p.write_text(s)
(root/'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>'+escape(base+'/')+'</loc></url></urlset>\n')
(root/'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: '+base+'/sitemap.xml\n')
print('SEO configured for '+base)
