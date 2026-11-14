from pathlib import Path
import urllib.request,zipfile,io,xml.etree.ElementTree as ET,csv,hashlib,json
root=Path(__file__).resolve().parents[1];out=root/'ios/VictoriaTracker/Resources/Growth';out.mkdir(exist_ok=True)
base='https://cdn.who.int/media/docs/default-source/child-growth/child-growth-standards/indicators/weight-for-age/expanded-tables/'
manifest=[]
ns={'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
for sex,label in [('female','girls'),('male','boys')]:
 url=base+f'wfa-{label}-zscore-expanded-tables.xlsx?sfvrsn='+('f01bc813_10' if sex=='female' else '65cce121_10')
 data=urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0','Referer':'https://www.who.int/'}),timeout=30).read()
 z=zipfile.ZipFile(io.BytesIO(data));strings=[]
 if 'xl/sharedStrings.xml' in z.namelist():
  strings=[''.join(i.itertext()) for i in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('m:si',ns)]
 rows=[]
 for row in ET.fromstring(z.read('xl/worksheets/sheet1.xml')).findall('.//m:row',ns):
  vals=[]
  for c in row.findall('m:c',ns):
   v=c.find('m:v',ns);s=v.text if v is not None else ''.join(c.itertext())
   if c.get('t')=='s':s=strings[int(s)]
   vals.append(s)
  rows.append(vals)
 print('Downloaded official WHO reference:',sex)
 # WHO expanded files use Day, L, M, S before the z-score columns.
 header=next(i for i,row in enumerate(rows) if row[:4]==['Day','L','M','S'])
 selected=[r[:4] for r in rows[header+1:] if r and r[0] and r[0].isdigit()]
 assert len(selected)==1857 and int(selected[0][0])==0 and int(selected[-1][0])==1856
 dest=out/f'who-weight-{sex}.csv'
 with dest.open('w') as f:
  w=csv.writer(f,lineterminator='\n');w.writerow(['day','L','M','S']);w.writerows(selected)
 manifest.append({'reference':'WHO Child Growth Standards (2006), expanded weight-for-age z-score tables','sex':sex,'source_url':url,'source_sha256':hashlib.sha256(data).hexdigest(),'csv_sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'rows':len(selected)})
(out/'SOURCE.json').write_text(json.dumps(manifest,indent=2)+'\n')
