# Kiểm chứng chức năng web — 2026-11-12

## Đã chạy với MongoDB thật

Binary chính thức MongoDB Community **8.0.16 và 9.0.7 macOS arm64**, tải từ `fastdl.mongodb.org`, chạy tại thư mục tạm, chỉ bind loopback. Test tạo keyfile và credential dùng một lần, không dùng tài khoản hoặc dữ liệu VPS.

`apps/mongodb_manager/tests/test_live_mongo.py` đã chạy thành công với ba tiến trình mongod:

- Khởi tạo cụm có primary và secondary với keyfile/auth.
- Ghi dữ liệu thật rồi tiếp nhận qua endpoint secondary bằng API của ứng dụng.
- Xác minh tự nhận tên replica set và cả hai member; đọc users/databases.
- Xác minh tiếp nhận không thay dữ liệu hoặc replica config/version.
- Sai mật khẩu bị từ chối và không sinh thêm hồ sơ.
- Gửi kế hoạch/xác nhận thêm member thứ ba qua API, chờ SECONDARY.
- Kiểm tra member mới non-voting/priority 0 và dữ liệu nguồn đọc được trên secondary mới.
- Kiểm tra password không xuất hiện trong phản hồi API.

Kết quả: **cùng integration test đạt trên cả hai phiên bản**: 8.0.16 mất 42,73 giây; 9.0.7 mất 49,44 giây. Các tiến trình test được dừng và client đóng trong teardown. Test này dùng MongoDB thật, không giả lập lệnh MongoDB. Sau khi thêm web authentication, đã chạy lại trên 9.0.7 với tài khoản web dùng một lần, cookie và CSRF thật qua API: đạt trong 43,80 giây.

## Các kiểm tra khác

`apps/mongodb_manager/tests/test_auth.py`, `apps/mongodb_manager/tests/test_web.py`, `apps/mongodb_manager/tests/test_ssh.py`: **43 test đạt**. Gồm validation, kế hoạch/xác nhận, mã hóa, che mật khẩu, quorum, phân biệt VPS nguồn/đích, chặn instance đã tồn tại trước khi cài; SSH password chạy qua giao thức SSH thật với server thử local, kiểm tra đúng/sai password và từ chối host key chưa biết.

Kiểm tra auth gồm: hash password, cookie HttpOnly/SameSite/Secure, session hết hạn/thu hồi/đổi credential, CSRF, chặn Host/Origin/HTTP sai ở public mode, rate limit và từ chối public startup thiếu admin. Đã đăng nhập bằng tài khoản quản trị trên browser thật, reload giữ phiên và logout trả lại trang đăng nhập.

JavaScript syntax, Python compile, bash syntax và `git diff --check` được chạy riêng khi bàn giao.

## Chưa kiểm chứng trên VPS

- DNS, cấp certificate HTTPS và reverse proxy Caddy trên tên miền thật. Public mode hiện được kiểm tra bằng TestClient mô phỏng HTTPS, chưa xác minh đường mạng/certificate thật.
- apt/repository, systemd và bootstrap mongosh trên Ubuntu 22.04/24.04/26.04 thật.
- Wizard cài/cấu hình VPS trống, chuyển keyfile nguồn → VPS đích qua SSH, rồi thêm member trong một lần chạy trên VPS.
- Firewall/mạng giữa VPS và máy quản trị. MongoDB 9.0.7 đã kiểm tra runtime trên macOS, chưa trên Linux.
- Backup và restore archive trên cụm thật.

Vì vậy kết quả local chứng minh luồng tiếp nhận và mở rộng MongoDB qua API đã chạy thật, chưa chứng minh mọi cấu hình VPS đều sẵn sàng. Với hồ sơ VPS được chủ sở hữu cung cấp, bước tiếp theo là kiểm tra chỉ đọc SSH/MongoDB và topology; chỉ cài hoặc thay membership khi người dùng yêu cầu trên đích cụ thể.

## Primary thay đổi / failover — đã chạy thật

Mở rộng integration test trên MongoDB Community **9.0.7**: thêm node thứ ba, nâng node đó thành voting/electable bằng API, lập kế hoạch tạo user trước bầu chọn, step down primary qua API, xác minh primary mới rồi shutdown node primary cũ. Sau đó mở kết nối mới bằng seed list đã lưu, đọc được primary mới, thực thi kế hoạch tạo user đã lập trước bầu chọn và xác minh user/dữ liệu trên cụm. Test đạt trong **62,61 giây**. Không tác động VPS người dùng.

UI tự refresh topology mỗi 10 giây khi tab hiển thị và không mở modal. Seed list cập nhật từ cấu hình replica set, dùng merge có kiểm tra seed cũ để tránh ghi đè chỉnh sửa kết nối đồng thời. Không tự retry lệnh quản trị không idempotent khi bầu chọn làm kết nối gián đoạn.

## Tiếp nhận cụm kèm SSH và lỗi seed — 2026-11-12

- Seed IP/hostname không port dùng 27017; IPv6 hỗ trợ dạng chuẩn. Thông báo 422 chỉ nêu trường lỗi, không phản chiếu credential.
- API tiếp nhận lưu cụm cùng nhiều SSH machine trong một transaction; endpoint SSH phải thuộc cụm đã xác minh, sửa hồ sơ giữ password khi để trống, phản hồi không lộ password. SSH sai thông tin không tạo nửa hồ sơ cụm.
- API lưu SSH riêng không kết nối MongoDB, dùng để lưu VPS phục vụ chẩn đoán khi cụm chưa truy cập được.
- Đã kiểm tra trên browser: lỗi seed chỉ rõ trường, xóa trạng thái loading khi thất bại, thêm hàng SSH password, cuộn nội dung trong khi header/footer vẫn hiển thị.
- Integration MongoDB 9.0.7 kèm web auth/CSRF, tiếp nhận qua secondary với SSH association, mở rộng và failover đạt trong 61,28 giây. SSH association test chỉ lưu cấu hình thử, không kết nối tới VPS thật.

## Kiểm tra trước khi thêm mọi loại member

Luồng SSH có role Secondary/Arbiter và chế độ chuẩn bị hoặc kiểm tra node đã chuẩn bị. Đối chiếu keyfile, phiên bản trước reconfig. Có kiểm tra tái sử dụng instance manager đúng cấu hình và giữ marker dữ liệu; khác replica set bị chặn. Tổng bộ auth/web/SSH: 47 test đạt. Integration MongoDB 9.0.7 thêm Secondary và failover chạy lại đạt 58,79 giây. Chưa chạy cài/cấu hình Arbiter qua SSH trên Ubuntu thật; không tuyên bố phần đó đã kiểm chứng VPS.

## Thử thực tế ORACLE trên Ubuntu 26.04.1 — 2026-11-13

Theo yêu cầu thêm thử rồi gỡ node của chủ sở hữu:

- VPS `161.118.198.188` có MongoDB 9.0.8 aarch64 chạy standalone trên localhost:27017. Port này bị chiếm nên không thể tạo thêm instance cùng port.
- Giữ nguyên standalone/service/dữ liệu; tạo instance riêng `rs0-oracle-test` tại port 27018, dùng keyfile nguồn từ member đang chạy và auth. Chỉ thêm rule UFW cho các member, IP máy quản trị và đường tự kết nối của VPS.
- Sửa lỗi kiểm tra buildInfo trên node chưa đồng bộ user (code 13 từng bị báo nhầm lỗi mạng). Luồng SSH dùng binary version đã xác minh; chẩn đoán hello không đòi user đã sync.
- Xác định firewall chặn đường VPS tự kết nối public endpoint, dẫn tới STARTUP; bổ sung rule hẹp cho đường self/NAT rồi node chuyển STARTUP2 và SECONDARY.
- Job `e5b166de1c5f4d8fa5c656fc6e15c876` hoàn tất. Node `161.118.198.188:27018` HEALTHY SECONDARY, votes=0, priority=0, phiên bản 9.0.8. Đối chiếu 9 bản ghi mẫu trong ExpressApiNew: 9/9 đọc được ở secondary. Không ghi dữ liệu thử vào database ứng dụng.
- Gỡ membership bằng job `178f8f53e6ce488abf42303938d66246`, xác minh cụm trở lại bốn member khỏe, dừng/disable service thử, thu hồi bảy rule UFW đã thêm. Service mongod cũ vẫn active. Giữ thư mục/config/dữ liệu thử để kiểm tra, không xóa.
- Không cần cài package mới vì binary đã có; việc apt install trên VPS trắng vẫn chưa được chứng minh bởi lần thử này.
- Bổ sung kiểm tra đường mạng từ đích tới chính endpoint quảng bá và các member trước reconfig; lỗi chiếm port nêu rõ cách xử lý.

## Gateway và ZM VPS Manager

Trên VM Ubuntu 24.04.5 ARM64 tách biệt, gateway đã kết nối SSH, cài Nginx qua Software Center, nhận diện lại gói đã cài và tạo reverse proxy tới ứng dụng thử ở localhost:3000. Domain thử dùng DNS cục bộ và trả HTTP 200. Upstream sai cổng và cấu hình Nginx không hợp lệ tạo job thất bại; website cũ vẫn trả HTTP 200. Hai yêu cầu cài gói đồng thời trả cùng mã tác vụ đang giữ khóa.

Kiểm thử trình duyệt ở 1280 px và 375 px đã mở hai giao diện trong một phiên, quay lại màn hình MongoDB trước đó và đăng xuất chung. Mỗi ứng dụng cũng chạy bộ test từ bản sao chỉ chứa thư mục ứng dụng và lõi chung.

Bộ test mặc định sau khi tách đạt 113 test, 3 test tích hợp cần binary riêng được bỏ qua. Khi chạy bổ sung với MongoDB 8.0.12 trên loopback, test bàn giao primary đạt. Test tiếp nhận secondary kèm hồ sơ SSH dùng 127.0.0.1 bị quy tắc VPS public từ chối. Đã tái hiện cùng lỗi trên bản mã trước khi di chuyển thư mục.
