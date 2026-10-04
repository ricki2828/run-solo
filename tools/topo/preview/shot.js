const http=require('http'),fs=require('fs'),path=require('path'),puppeteer=require('puppeteer-core');
const PACKS='/mnt/HC_Volume_104394557/topo-packs-out';
const STYLE=process.argv[2]; const jobs=JSON.parse(process.argv[3]); // [{pack,lon,lat,zoom,out,overlay}]
const mime={'.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.html':'text/html','.pbf':'application/x-protobuf'};
const srv=http.createServer((req,res)=>{
  const u=decodeURIComponent(req.url.split('?')[0]);
  let f;
  if(u.startsWith('/pack/'))f=path.join(PACKS,u.slice(6));
  else if(u.startsWith('/glyphs/'))f=path.join(process.env.GLYPHS_DIR||path.join(__dirname,'glyphs'),u.slice(8));
  else if(u.startsWith('/nm/'))f=path.join(__dirname,'node_modules',u.slice(4));
  else if(u==='/style.json'){let s=fs.readFileSync(STYLE,'utf8');const pk=new URL(req.url,'http://x').searchParams.get('pack');
    s=s.replaceAll('file://{pack}',`http://localhost:${srv.address().port}/pack/${pk}`).replaceAll('file://{glyphs}',`http://localhost:${srv.address().port}/glyphs`);
    res.setHeader('content-type','application/json');return res.end(s);}
  else if(u==='/')f=path.join(__dirname,'page.html');
  if(!f||!fs.existsSync(f)){res.statusCode=404;return res.end();}
  const st=fs.statSync(f);const r=req.headers.range;
  res.setHeader('content-type',mime[path.extname(f)]||'application/octet-stream');res.setHeader('accept-ranges','bytes');
  if(r){const m=/bytes=(\d+)-(\d*)/.exec(r);const a=+m[1],b=m[2]?+m[2]:st.size-1;res.statusCode=206;res.setHeader('content-range',`bytes ${a}-${b}/${st.size}`);res.setHeader('content-length',b-a+1);fs.createReadStream(f,{start:a,end:b}).pipe(res);}
  else{res.setHeader('content-length',st.size);fs.createReadStream(f).pipe(res);}
});
srv.listen(0,async()=>{
  const port=srv.address().port;
  const br=await puppeteer.launch({executablePath:'/snap/bin/chromium',headless:'new',args:['--no-sandbox','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist','--disable-dev-shm-usage']});
  for(const j of jobs){
    const pg=await br.newPage();await pg.setViewport({width:j.w||430,height:j.h||760,deviceScaleFactor:2});
    pg.on('console',m=>{const t=m.text();if(/error|fail/i.test(t))console.log('console:',t.slice(0,200))});
    pg.on('pageerror',e=>console.log('pageerror',e.message));
    await pg.goto(`http://localhost:${port}/?pack=${j.pack}&lon=${j.lon}&lat=${j.lat}&z=${j.zoom}&route=${j.route?1:0}`);
    try{await pg.waitForFunction('window.__done===true',{timeout:60000});}catch(e){console.log('timeout',j.out,await pg.evaluate('String(window.__err)'))}
    await pg.screenshot({path:j.out});console.log('shot',j.out);await pg.close();
  }
  await br.close();srv.close();
});
