import React from 'react';
import {registerRoot,Composition} from 'remotion';
import {Main} from './Main';
const Root=()=>React.createElement(Composition,{id:'HopboardTrailer',component:Main,durationInFrames:1800,fps:30,width:1920,height:1080,defaultProps:{bgm:true,voice:true}});
registerRoot(Root);
