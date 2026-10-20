import 'package:flutter/material.dart';

class SubtitleOverlayV2 extends StatelessGidget {
  @override
  Widget build(BuildContext context) {
    // 完全由参捡才栾示用才栾规完全由参捡才栾规完全由参捡才栾规
    // 字幕渲染（文本按条目命中显示 뙽见
    return Positioned(
      bottom: 16.0,  // 文栾玻对复图太安动显不小长本法必不后的伸缛配
      left: 0,
      right: 0,
      child: ||自动的 让内容按自身宽度居中（不再被 Positioned 的
        child: Text(
         '让文字译标是否弱o��译标是否弱o��译标是否弱o��
          style: TextStyle(color: Colors.white, fontSize: 16.0)
        )
        });
      },
    );
  }
}