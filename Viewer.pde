/*================================================================================
 * MLX90640 raw file viewer
 * Copyright (c) 2024 embedded-kiddie
 * Released under the MIT license
 * https://opensource.org/license/mit
 *================================================================================*/
import java.io.*;   // RandomAccessFile
import java.nio.*;  // ByteBuffer, ByteOrder

// MLX90640 device resolution
int MLX90640_COLS = 32;
int MLX90640_ROWS = 24;
int MLX90640_SIZE  = (MLX90640_COLS * MLX90640_ROWS);
int MLX90640_FRAME = (MLX90640_COLS * MLX90640_ROWS * 4);

// Interpolation: false
int DISPLAY_SCALE = 15;  // Box size
int DISPLAY_FILTER = 7;  // Gaussian filter size (0: none)
int DISPLAY_COLS = (MLX90640_COLS * DISPLAY_SCALE);
int DISPLAY_ROWS = (MLX90640_ROWS * DISPLAY_SCALE);

// Interpolation: true
int INTERPOLATE_BOX = 1;
int INTERPOLATE_SCALE = DISPLAY_SCALE;
int INTERPOLATED_COLS = (MLX90640_COLS * INTERPOLATE_SCALE);
int INTERPOLATED_ROWS = (MLX90640_ROWS * INTERPOLATE_SCALE);
int INTERPOLATED_SIZE = (INTERPOLATED_COLS * INTERPOLATED_ROWS);

/*--------------------------------------------------------------------------------
 * Heatmap: Inferno
 * https://matplotlib.org/stable/users/explain/colors/colormaps.html
 *--------------------------------------------------------------------------------*/
int N_POINTS = 25;
int N_GRADATION = 1024;
float calcR(float x) { float y = -0.0186f * pow(x, 3.0f) + 0.3123f * pow(x, 2.0f) + 11.9230f * x + 36.6580f; return constrain(y, 0.0f, 255.0f); }
float calcG(float x) { float y =  0.0042f * pow(x, 3.0f) + 0.2183f * pow(x, 2.0f) +  1.0843f * x +  8.0676f; return constrain(y, 0.0f, 255.0f); }
float calcB(float x) { float y =  0.0743f * pow(x, 3.0f) - 2.7407f * pow(x, 2.0f) + 23.1360f * x + 61.5370f; return constrain(y, 0.0f, 255.0f); }

// Default range of temperature
int MINTEMP = 20;  // Low  temperature range
int MAXTEMP = 35;  // High temperature range

public class HeatMap {
  public float[] r = new float[N_GRADATION];
  public float[] g = new float[N_GRADATION];
  public float[] b = new float[N_GRADATION];

  public HeatMap() {
    float x = 1.0f;
    float step = (float)(N_POINTS - 1) / (float)N_GRADATION;

    for (int i = 0; i < N_GRADATION; i++, x += step) {
      r[i] = calcR(x);
      g[i] = calcG(x);
      b[i] = calcB(x);
    }
  }
}

/*--------------------------------------------------------------------------------
 * Pixel Bilinear interpolation
 *--------------------------------------------------------------------------------*/
public class Interpolate {
  private float ratio[][];

  private void init(int scale) {
    ratio = new float[scale][2];
    for (int i = 0; i < scale; i++) {
      ratio[i][0] = (float)i / (float)scale;
      ratio[i][1] = 1.0f - ratio[i][0];
    }
  }

  private float get_point(float[] p, int rows, int cols, int x, int y) {
    if (x < 0) { x = 0; }
    if (y < 0) { y = 0; }
    if (x >= cols) { x = cols - 1; }
    if (y >= rows) { y = rows - 1; }
    return p[y * cols + x];
  }

  public Interpolate(int scale) {
    init(scale);
  }
  public Interpolate() {
    init(INTERPOLATE_SCALE);
  }
  
  public void interpolate(float[] src, int rows, int cols, float[] dst, int scale) {
    int X, Y;
    int dst_cols = scale * MLX90640_COLS;
    float X0Y0, X1Y0, X0Y1, X1Y1;
    float x_ratio_lo, x_ratio_hi;
    float y_ratio_lo, y_ratio_hi;
    float v0, v1, w0, w1;

    // Bilinear interpolation
    for (int y = 0; y < rows; y++) {
      Y = y * scale;

      for (int x = 0; x < cols; x++) {
        X = x * scale;

        X0Y0 = get_point(src, rows, cols, x,     y    );
        X1Y0 = get_point(src, rows, cols, x + 1, y    );
        X0Y1 = get_point(src, rows, cols, x,     y + 1);
        X1Y1 = get_point(src, rows, cols, x + 1, y + 1);

        for (int j = 0; j < scale; j++) {
          y_ratio_lo = ratio[j][0];
          y_ratio_hi = ratio[j][1];

          v0 = y_ratio_hi * X0Y0;
          v1 = y_ratio_hi * X1Y0;
          w0 = y_ratio_lo * X0Y1;
          w1 = y_ratio_lo * X1Y1;

          for (int i = 0; i < scale; i++) {
            x_ratio_lo = ratio[i][0];
            x_ratio_hi = ratio[i][1];
  
            float t = v0 * x_ratio_hi + v1 * x_ratio_lo +
                      w0 * x_ratio_hi + w1 * x_ratio_lo;

            // Is it okay to leave it to the compiler to optimize?
            dst[(X + i) + (Y + j) * dst_cols] = t;
          }
        }
      }
    }
  }
}

/*--------------------------------------------------------------------------------
 * Viewer class
 *--------------------------------------------------------------------------------*/
public class Viewer {
  private boolean autoRange = false;
  private boolean interpolation = true;
  private float minTmp = +999.0f;
  private float maxTmp = -999.0f;
  private int filterSize = DISPLAY_FILTER;

  private HeatMap heatmap = null;
  private Interpolate pol = null;
  private RandomAccessFile reader = null;

  private long frameNo = 0;
  private long frameCount = 0;
  private float[] src = new float[MLX90640_SIZE];
  private float[] dst = new float[INTERPOLATED_ROWS * INTERPOLATED_COLS];
  private int  [] tmp = new int  [INTERPOLATED_ROWS * INTERPOLATED_COLS];
  private PGraphics colorBar = createGraphics(480, 30);

  public Viewer(String filename) {
    // Graphics setting
    noStroke();
    textSize(32);
    colorMode(RGB);

    // Related instances
    pol = new Interpolate();
    heatmap = new HeatMap();

    // Create heatmap color bar
    colorBar.beginDraw();
    colorBar.noStroke();
    colorBar.colorMode(RGB);
    for (int i = 0; i < N_GRADATION; i++) {
      int x = floor(map(i, 0, N_GRADATION, 0, 480));
      colorBar.fill(heatmap.r[i], heatmap.g[i], heatmap.b[i]);
      colorBar.rect(x, 0, 1, 30);
    }
    colorBar.endDraw();

    // Create file reader object
    try {
      // https://zawaworks.hatenablog.com/entry/2017/10/08/213602
      reader = new RandomAccessFile(sketchPath() + "/" + filename, "r");
      frameCount = reader.length() / MLX90640_FRAME;
      frameNo = 0;
      println("frameCount: " + frameCount);
    }
    catch (FileNotFoundException e) {
      e.printStackTrace();
      exit();
    }
    catch (IOException e) {
      e.printStackTrace();
      exit();
    }
  }

  public void SetRange(boolean _autoRange) {
    autoRange = _autoRange;
  }
  public void SetRange(int _minTmp, int _maxTmp) {
    minTmp = _minTmp;
    maxTmp = _maxTmp;
  }

  public void SetInterpolation(boolean _interpolation) {
    interpolation = _interpolation;
  }

  public void SetFilterSize(int _filterSize) {
    filterSize = _filterSize;
  }

  public void Read(long n) {
    try {
      reader.seek(n * MLX90640_FRAME);
      
      byte[] buffer = new byte[4];
      for (int i = 0; i < MLX90640_SIZE; i++) {
        if (reader.read(buffer) != 4) {
          throw new IOException("Unexpected End of Stream");
        }

        // https://www.jpcert.or.jp/java-rules/fio12-j.html
        src[i] = ByteBuffer.wrap(buffer).order(ByteOrder.LITTLE_ENDIAN).getFloat();
      }
    }
    catch (IOException e) {
      e.printStackTrace();
      exit();
    }
  }

  public void Rewind() {
    frameNo = 0;
  }

  public boolean Next() {
    if (frameNo < frameCount - 1) {
      frameNo++;
      return true;
    } else {
      return false;
    }
  }

  public boolean Prev() {
    if (frameNo > 0) {
      frameNo--;
      return true;
    } else {
      return false;
    }
  }

  void Draw() {
    Read(frameNo);  // Read frame into src[]
    background(0);

    maxTmp = -999.0f;
    minTmp = +999.0f;

    if (autoRange) {
      // For each floating point value, double check that we've acquired a number,
      // then determine the min and max temperature values for this frame
      for (int i = 0; i < MLX90640_SIZE; i++) {
        if (Float.isNaN(src[i])) continue;
        if (src[i] > maxTmp) {
          maxTmp = src[i];
        } else if (src[i] < minTmp) {
          minTmp = src[i];
        }
      }
      maxTmp = floor(maxTmp);
      minTmp = floor(minTmp);
    } else {
      maxTmp = MAXTEMP;
      minTmp = MINTEMP;
    }

    float [] img = src;
    int size = MLX90640_SIZE;
    int rows = DISPLAY_ROWS;
    int cols = DISPLAY_COLS;
    int step = DISPLAY_SCALE;

    // Pixel interpolation by Bilinear interpolation
    if (interpolation) {
      pol.interpolate(src, MLX90640_ROWS, MLX90640_COLS, dst, INTERPOLATE_SCALE);
      img = dst;
      size = INTERPOLATED_SIZE;
      rows = INTERPOLATED_ROWS;
      cols = INTERPOLATED_COLS;
      step = INTERPOLATE_BOX;
    }

    // Scale temperature between min and max
    for (int i = 0; i < size; i++) {
      if (!Float.isNaN(img[i])) {
        int t = round(map(img[i], minTmp, maxTmp, 0.0f, (float)(N_GRADATION - 1)));
        tmp[i] = constrain(t, 0, N_GRADATION - 1);
      } else {
        tmp[i] = 0;
      }
    }

    // Draw image
    int i = 0;
    for (int y = 0; y < rows; y += step) {
      for (int x = 0; x < cols; x += step) {
        int t = tmp[i++];
        fill(heatmap.r[t], heatmap.g[t], heatmap.b[t]);
        rect(x, y, step, step);
      }
    }

    // Apply Gaussian blur filter
    if (!interpolation) {
      filter(BLUR, filterSize);
    }

    // Draw heatmap color bar
    image(colorBar, 0, 360);

    // Draw legend
    fill(#FFFFFF);
    textAlign(LEFT, TOP);
    text(String.format("%d°C", (int)minTmp), 0, 390);
    textAlign(RIGHT, TOP);
    text(String.format("%d°C", (int)maxTmp), 479, 390);
    textAlign(CENTER, TOP);
    text(String.format("%.1f", (maxTmp + minTmp) / 2.0f), 240, 390);
  }
}
