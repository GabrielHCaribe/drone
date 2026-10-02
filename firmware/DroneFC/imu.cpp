#include "imu.h"
#include <Arduino.h>
#include <SPI.h>
#include "config.h"

// MPU6500 registers
#define REG_SMPLRT_DIV 0x19
#define REG_CONFIG 0x1A
#define REG_GYRO_CONFIG 0x1B
#define REG_ACCEL_CONFIG 0x1C
#define REG_ACCEL_CONFIG2 0x1D
#define REG_INT_PIN_CFG 0x37
#define REG_INT_ENABLE 0x38
#define REG_ACCEL_XOUT_H 0x3B
#define REG_SIGNAL_PATH_RESET 0x68
#define REG_USER_CTRL 0x6A
#define REG_PWR_MGMT_1 0x6B
#define REG_PWR_MGMT_2 0x6C
#define REG_WHO_AM_I 0x75

static const float GYRO_SCALE = 1.0f / 16.4f;     // +-2000 deg/s
static const float ACCEL_SCALE = 1.0f / 4096.0f;  // +-8 g

static SPIClass s_spi(VSPI);
static uint8_t s_whoami = 0;

static void write_reg(uint8_t reg, uint8_t val) {
  s_spi.beginTransaction(SPISettings(IMU_SPI_SLOW_HZ, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_IMU_CS, LOW);
  s_spi.transfer(reg & 0x7F);
  s_spi.transfer(val);
  digitalWrite(PIN_IMU_CS, HIGH);
  s_spi.endTransaction();
  delayMicroseconds(10);
}

static uint8_t read_reg(uint8_t reg) {
  s_spi.beginTransaction(SPISettings(IMU_SPI_SLOW_HZ, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_IMU_CS, LOW);
  s_spi.transfer(reg | 0x80);
  uint8_t v = s_spi.transfer(0x00);
  digitalWrite(PIN_IMU_CS, HIGH);
  s_spi.endTransaction();
  return v;
}

uint8_t imu_whoami() { return s_whoami; }

bool imu_init() {
  pinMode(PIN_IMU_CS, OUTPUT);
  digitalWrite(PIN_IMU_CS, HIGH);
  pinMode(PIN_IMU_INT, INPUT);
  s_spi.begin(PIN_IMU_SCLK, PIN_IMU_MISO, PIN_IMU_MOSI, PIN_IMU_CS);

  write_reg(REG_PWR_MGMT_1, 0x80);  // device reset
  delay(100);
  write_reg(REG_SIGNAL_PATH_RESET, 0x07);
  delay(100);
  write_reg(REG_USER_CTRL, 0x10);   // I2C_IF_DIS: SPI only
  write_reg(REG_PWR_MGMT_1, 0x01);  // clock = gyro PLL
  delay(10);

  s_whoami = read_reg(REG_WHO_AM_I);
  // 0x70 = MPU6500. Many "MPU6500" boards carry a relabelled sibling:
  // 0x71 MPU9250, 0x73 MPU9255, 0x74 MPU6515, 0x75 clone. All share these registers.
  bool known = s_whoami == 0x70 || s_whoami == 0x71 || s_whoami == 0x73 || s_whoami == 0x74 || s_whoami == 0x75;
  if (!known) return false;

  write_reg(REG_PWR_MGMT_2, 0x00);                    // all axes on
  write_reg(REG_CONFIG, IMU_GYRO_DLPF_CFG & 0x07);    // gyro DLPF -> 1 kHz internal rate
  write_reg(REG_SMPLRT_DIV, 0x00);                    // 1 kHz output
  write_reg(REG_GYRO_CONFIG, 0x18);                   // +-2000 deg/s, FCHOICE_B = 00
  write_reg(REG_ACCEL_CONFIG, 0x10);                  // +-8 g
  write_reg(REG_ACCEL_CONFIG2, IMU_ACCEL_DLPF_CFG & 0x07);
  write_reg(REG_INT_PIN_CFG, 0x10);                   // active high, push-pull, 50 us pulse, clear on any read
  write_reg(REG_INT_ENABLE, 0x01);                    // raw data ready
  delay(20);

  // Sanity check that the configuration stuck.
  return read_reg(REG_GYRO_CONFIG) == 0x18 && read_reg(REG_ACCEL_CONFIG) == 0x10;
}

static inline int16_t be16(const uint8_t* p) { return (int16_t)((p[0] << 8) | p[1]); }

// Rotate a sensor-frame vector into the body frame (FLU).
static inline void to_body(float sx, float sy, float sz, float& bx, float& by, float& bz) {
#if IMU_ROTATION_DEG == 0
  bx = sx; by = sy;
#elif IMU_ROTATION_DEG == 90   // X arrow points to the RIGHT
  bx = sy; by = -sx;
#elif IMU_ROTATION_DEG == 180  // X arrow points to the BACK
  bx = -sx; by = -sy;
#elif IMU_ROTATION_DEG == 270  // X arrow points to the LEFT
  bx = -sy; by = sx;
#else
#error "IMU_ROTATION_DEG must be 0, 90, 180 or 270"
#endif
  bz = sz;
#if IMU_UPSIDE_DOWN
  by = -by;  // 180 deg flip about the forward axis
  bz = -bz;
#endif
}

bool imu_read(ImuSample& out) {
  uint8_t buf[15];
  memset(buf, 0, sizeof(buf));
  buf[0] = REG_ACCEL_XOUT_H | 0x80;
  s_spi.beginTransaction(SPISettings(IMU_SPI_FAST_HZ, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_IMU_CS, LOW);
  s_spi.transfer(buf, sizeof(buf));
  digitalWrite(PIN_IMU_CS, HIGH);
  s_spi.endTransaction();

  const uint8_t* d = buf + 1;
  int16_t rax = be16(d + 0), ray = be16(d + 2), raz = be16(d + 4);
  int16_t rgx = be16(d + 8), rgy = be16(d + 10), rgz = be16(d + 12);

  // A disconnected MISO line reads all 0x00 or all 0xFF.
  if ((rax == 0 && ray == 0 && raz == 0) || (rax == -1 && ray == -1 && raz == -1)) return false;

  to_body(rax * ACCEL_SCALE, ray * ACCEL_SCALE, raz * ACCEL_SCALE, out.ax, out.ay, out.az);
  to_body(rgx * GYRO_SCALE, rgy * GYRO_SCALE, rgz * GYRO_SCALE, out.gx, out.gy, out.gz);
  return true;
}
