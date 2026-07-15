# Telegram Power Monitor

Ứng dụng gửi Telegram cho ba sự kiện độc lập:

- Windows khởi động và máy online.
- Windows thực sự resume từ sleep/hibernate.
- Windows được dự đoán còn khoảng 10 giây trước sleep tự động và lần kiểm tra input cuối không bị reset.

Watcher ưu tiên countdown chính thức của power manager. Khi máy không cung cấp countdown, nó suy ra từ `GetLastInputInfo` của đúng phiên người dùng cộng với thiết lập **Sleep after** của Windows. Ngay trước khi gửi, watcher đọc lại input lần nữa; chuột/phím local hoặc remote đều hủy chu kỳ nếu timer đã reset. Khi video, driver hoặc ứng dụng yêu cầu giữ System/Display thức, `SystemExecutionState` cũng chặn tin pre-sleep.

Shutdown thủ công không gửi thông báo vì Windows có thể cắt mạng và tiến trình ngay lập tức.

## Cài đặt

1. Nhấp đúp `INSTALL.cmd`.
2. Lần đầu cài, nhập Bot token và Chat ID trong cửa sổ **Telegram settings**, rồi bấm **Save**.
3. Chấp nhận quyền Administrator.

Nếu thư mục còn `config.ps1` của phiên bản cũ, installer tự chuyển dữ liệu sang JSON rồi xóa file cũ. Token không còn nằm trong mã PowerShell.

Cấu hình sau khi cài nằm tại:

```text
C:\ProgramData\TelegramPowerMonitor\config.json
```

Thư mục này chỉ cấp quyền cho tài khoản đã cài ứng dụng, Administrators và SYSTEM. File `config.json` tạm trong thư mục app cũng được xóa sau khi cài thành công.

Muốn nhập bằng terminal thay vì form:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\setup-config.ps1" -Console
```

Muốn sửa về sau, nhấp phải biểu tượng Telegram Power Monitor ở khay hệ thống và chọn **Telegram settings...**. Không cần cài lại task sau khi chỉ đổi token hoặc Chat ID.

Các mục chính trong menu khay:

- **Status**: mở trạng thái task và log gần nhất.
- **Telegram settings...**: sửa token/Chat ID trong form, không hiện console.
- **Send test message**: gửi một tin thử và báo lại kết quả.
- **Enable/Disable scheduled tasks**: yêu cầu UAC, bật/tắt toàn bộ task và khởi động/dừng watcher tương ứng. Hai mục này bị vô hiệu hóa nếu task chưa được cài đủ.
- **Install / repair tasks** và **Uninstall tasks**: mở trình cài/gỡ có cửa sổ để người dùng xem kết quả.
- **Open log**, **Open folder** và **Exit tray**: mở log, thư mục app hoặc chỉ thoát biểu tượng khay.

Cài bằng PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -PreSleepSeconds 10 -MaxProbeIntervalSeconds 60 -LogRetentionDays 5
```

- `PreSleepSeconds`: thời điểm dự kiến gửi trước khi bộ đếm sleep hết hạn.
- `MaxProbeIntervalSeconds`: khoảng nghỉ tối đa của watcher; watcher tự rút ngắn khoảng nghỉ khi gần sleep.
- `LogRetentionDays`: số ngày giữ log, mặc định 5 ngày tính cả hôm nay.

## Cách hoạt động

### Startup

Task SYSTEM chạy sau boot 30 giây để chờ mạng. Mỗi Windows boot chỉ gửi một lần. Hibernate resume được giao riêng cho task Resume để tránh gửi trùng.

### Resume

Task SYSTEM lắng nghe `Microsoft-Windows-Power-Troubleshooter`, Event ID 1, rồi chờ 30 giây cho mạng. Resume được chống trùng theo `EventRecordID`, độc lập với tin pre-sleep. Sự kiện trung gian chuyển sang S4/hibernate bị bỏ qua; lần wake thật vẫn gửi.

### Pre-sleep tự động

Watcher chạy ẩn trong phiên người dùng tương tác để Windows tính đúng chuột/phím local và remote. Task Startup/Resume vẫn chạy dưới SYSTEM. Watcher không mở cửa sổ CMD/PowerShell và chọn timer theo thứ tự:

- Dùng `SYSTEM_POWER_INFORMATION.TimeRemaining` khi máy có cung cấp countdown.
- Nếu countdown là `0xFFFFFFFF`, dùng `GetLastInputInfo` và **Sleep after** để tạo countdown tương đương trong phiên người dùng tương tác.
- Nếu có yêu cầu giữ System/Display thức: không gửi, kể cả idle đã dài.
- Còn nhiều thời gian: watcher nghỉ và tự chọn thời điểm kiểm tra tiếp.
- Còn khoảng 10 giây: watcher đợi ngắn và đọc lại `GetLastInputInfo`. Nếu idle giảm, countdown tăng, nguồn timer đổi hoặc xuất hiện yêu cầu giữ System/Display thức thì hủy gửi và cập nhật vòng lặp. Watcher còn truyền `dwTime` sang sender để đối chiếu lần cuối ngay sát lệnh gọi Telegram; input thay đổi trong lúc sender khởi động cũng hủy gửi.
- Nếu input vẫn không đổi: gửi Telegram một lần, rồi kiểm tra bộ đếm sleep khoảng 10-15 giây sau.
- Nếu Windows vẫn chưa sleep: chu kỳ vừa gửi bị đánh dấu `PRE_SLEEP_NOT_CONFIRMED`; watcher lấy thời điểm đó làm mốc chu kỳ mới và không gửi lặp ngay.

Watcher đồng thời đăng ký `PowerRegisterSuspendResumeNotification`. Khi nhận `PBT_APMSUSPEND`, callback không thực hiện mạng. Sau resume, nó kiểm tra chu kỳ Telegram gần nhất rồi hiển thị `PreSleepTelegramConfirmed=True/False` trong log và **Status**.

## Kiểm tra

Xem task, trạng thái notification và log gần nhất:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\status.ps1"
```

Probe power state một lần, không gửi Telegram:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\watch-power.ps1" -ProbeOnce
```

Kiểm tra máy có đăng ký được callback suspend hay không, không đưa máy vào sleep:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\watch-power.ps1" -ProbeSuspendAudit
```

Gửi test thủ công:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\test-send.ps1"
```

## Gỡ cài đặt

Nhấp đúp `UNINSTALL.cmd`. Mặc định uninstaller dừng tiến trình, xóa toàn bộ Scheduled Task mới/cũ, shortcut Startup, wrapper legacy, thư mục runtime trong ProgramData, token/Chat ID, state, file tạm và log; sau đó hậu kiểm và báo lỗi nếu còn sót.

Chỉ khi cần giữ cấu hình và log để chẩn đoán mới chạy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\uninstall.ps1" -KeepData
```

Giữ log nhưng xóa riêng cấu hình Telegram:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\uninstall.ps1" -KeepData -RemoveConfig
```

## Giới hạn thực tế

Tin pre-sleep là dự đoán best effort từ countdown/input idle. Hoạt động hệ thống không tạo input có thể làm Windows dời sleep; vì vậy watcher hậu kiểm sau 10-15 giây và tạo chu kỳ mới nếu máy vẫn thức. Startup và resume đáng tin cậy hơn vì chúng có thể chờ mạng.
