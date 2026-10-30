import {mkdirSync} from 'node:fs';
import {bundle} from '@remotion/bundler';
import {openBrowser,renderStill,selectComposition} from '@remotion/renderer';
mkdirSync('out/posters',{recursive:true});
const serveUrl=await bundle({entryPoint:'src/index.ts'});
const browser=await openBrowser('chrome');
const composition=await selectComposition({serveUrl,id:'HopboardTrailer',chromiumInstance:browser});
for(const f of [270,420,570,870,1020,1170,1320,1395,1620,1799]){
 await renderStill({serveUrl,composition,frame:f,output:`out/posters/f${f}.png`,imageFormat:'jpeg',jpegQuality:88,chromiumInstance:browser});
 console.log('poster',f);
}
await browser.close({silent:true});
