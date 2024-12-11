/*================================================================================
 * MLX90640 raw file viewer
 * Copyright (c) 2024 embedded-kiddie
 * Released under the MIT license
 * https://opensource.org/license/mit
 *================================================================================*/
Viewer viewer;
int counter = 0;

// MLX90640 raw file
String file = "./data/mlx0100.raw";

void setup() {
  size(480, 420);
  frameRate(16);
  viewer = new Viewer(file);
  viewer.Rewind();
  viewer.SetFilterSize(0);
  viewer.SetInterpolation(false);
}

void draw() {
  viewer.Draw();
  if (!viewer.Next()) {
    viewer.Rewind();
    switch (++counter % 3) {
      case 0:
        viewer.SetFilterSize(0);
        viewer.SetInterpolation(false);
        break;
      case 1:
        viewer.SetInterpolation(true);
        break;
      case 2:
        viewer.SetFilterSize(7);
        viewer.SetInterpolation(false);
        break;
    }
  }
}
