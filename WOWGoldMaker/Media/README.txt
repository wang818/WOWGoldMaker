Media 目录下全部素材由 tools/gen_media.py 生成:

  panel      主面板底 (深色渐变 + 圆角 + 描边, 512x312)
  shadow     面板投影 (512x328)
  card       数据卡片蒙版 (256x118)
  btn        按钮蒙版 (268x74)
  sq         方形控件蒙版 / 勾选框 (64x64)
  glow       柔光 (径向指数衰减)
  glow-soft  大范围氛围光
  circle     圆形蒙版 (用于图标裁切)

TGA 是 32 位未压缩、左下原点, WoW 客户端直接引用 (无扩展名)。
PNG 是同款内容, 仅供本地 preview.html 预览, 游戏不读取。

重新生成: python tools/gen_media.py
