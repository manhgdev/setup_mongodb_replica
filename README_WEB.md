# MongoDB Manager

Giao diện tiếng Việt với backend FastAPI, dùng trên máy quản trị để kết nối MongoDB và thực thi công việc trên máy local hoặc VPS qua SSH.

## Chạy

Yêu cầu Python 3.10 trở lên, có module `venv` và pip. Tại thư mục repository:

```bash
bash start-web.sh
```

Mở http://127.0.0.1:8765. Lần đầu script tạo `.venv` và cài `requirements-web.txt`. Dừng bằng Ctrl+C. Chế độ **Xem thử giao diện** dùng dữ liệu giả và chỉ mô phỏng tác vụ; chọn **Chuyển sang dữ liệu thật** để quản lý hệ thống.

## Chạy trên máy cá nhân hoặc VPS

Chạy trên máy cá nhân: thêm các VPS qua SSH để quản trị từ đây. SSH key, known_hosts, CA path và `.web-data` nằm trên máy cá nhân.

Chạy trên VPS: đóng gói bằng `bash package-web.sh`, tải `dist/mongodb-manager-web.tar.gz` lên VPS rồi giải nén vào một thư mục riêng. Gói không chứa `.venv`, credential hoặc `.web-data` của máy cá nhân.

```bash
# Trên Ubuntu VPS
sudo apt-get update
sudo apt-get install -y python3 python3-venv
mkdir -p ~/mongodb-manager
tar -xzf mongodb-manager-web.tar.gz -C ~/mongodb-manager
cd ~/mongodb-manager
bash start-web.sh
```

Từ máy cá nhân mở tunnel (port 8766 để không trùng ứng dụng đang chạy local):

```bash
ssh -N -L 8766:127.0.0.1:8765 user@IP_VPS
```

Mở http://127.0.0.1:8766. Giữ tiến trình web và SSH tunnel đang chạy; có thể chạy web trong `tmux` trên VPS để tiếp tục khi ngắt terminal. Ứng dụng vẫn chỉ bind localhost, không cần mở port web ra Internet. Khi chạy trên VPS, **Local** là VPS đó; SSH key/known_hosts và đường kết nối đến các member cũng được kiểm tra từ VPS đó. Thông tin lưu trên máy cá nhân không tự chuyển sang workspace trên VPS.

## Tài khoản quản trị và tên miền HTTPS

Lần đầu mở Manager tại localhost, tạo tài khoản trên trang khởi tạo để tự đăng nhập vào workspace. Có thể bấm avatar để sửa tài khoản sau khi đăng nhập. Cũng có thể tạo tài khoản bằng terminal trên máy chạy web (password nhập ẩn, không có mật khẩu mặc định trong gói):

Sau khi tạo hoặc sửa tài khoản quản trị, lưu mã khôi phục hiển thị trong popup. Khi quên mật khẩu, bấm **Quên mật khẩu?**, nhập tên đăng nhập, mã và mật khẩu mới. Manager vô hiệu hóa các phiên đăng nhập cũ và cấp mã mới thay cho mã vừa dùng. Với tài khoản cũ chưa có mã, vào **Sửa tài khoản quản trị**, xác nhận mật khẩu hiện tại và lưu để nhận mã. Nếu đã mất cả mật khẩu lẫn mã, trên máy chạy Manager dùng `.venv/bin/python -m web.manage create-admin --username TEN_DANG_NHAP --replace` với đúng thư mục dữ liệu rồi khởi động lại Manager.


```bash
.venv/bin/python -m web.manage create-admin --username manhg
```

Khởi động lại ứng dụng rồi đăng nhập. Để đổi mật khẩu hoặc khôi phục truy cập, chạy lại lệnh với `--replace`, sau đó restart; các phiên cũ hết hiệu lực. `admin.json` chỉ chứa hash scrypt, có quyền 0600. Phiên đăng nhập dùng cookie HttpOnly/SameSite Strict, hết hạn sau 8 giờ hoặc 30 phút không hoạt động, token được lưu phía server. Mỗi IP bị tạm chặn sau 5 lần sai trong 15 phút; có giới hạn chung để chống thử hàng loạt. Logout thu hồi session phía server. Các tác vụ đã chạy vẫn tiếp tục khi logout.

Không có tài khoản: chỉ dùng được chế độ localhost cũ. **Chế độ domain từ chối khởi động nếu chưa có tài khoản.**

Để dùng domain công khai, sau khi trỏ DNS vào VPS và mở 80/443 cho reverse proxy:

```bash
.venv/bin/python -m web.manage configure-domain --url https://mongo.example.com
```

Thay hostname trong `deploy/Caddyfile` bằng domain thật và đặt file tại `/etc/caddy/Caddyfile`. Caddy giữ nguyên Host, cấp HTTPS và chuyển đến backend `127.0.0.1:8765`; backend kiểm tra chính xác Host + HTTPS + Origin đã cấu hình. Không tự đổi Host thành localhost và không mở port 8765 ra Internet. Tham khảo [cài Caddy](https://caddyserver.com/docs/install) và [reverse proxy HTTPS](https://caddyserver.com/docs/quick-starts/reverse-proxy).

Mẫu `deploy/mongodb-manager.service` chạy app dưới user riêng, khởi động lại khi lỗi. Với app đã giải nén tại `/opt/mongodb-manager`, tạo venv/dependency trước (có thể dùng `bash start-web.sh` lần đầu rồi Ctrl+C), sau đó:

```bash
sudo useradd --system --create-home --home-dir /var/lib/mongodb-manager-web --shell /usr/sbin/nologin mongodb-manager
sudo install -d -m 700 -o mongodb-manager -g mongodb-manager /var/lib/mongodb-manager-web
sudo -u mongodb-manager /opt/mongodb-manager/.venv/bin/python -m web.manage --data-dir /var/lib/mongodb-manager-web create-admin --username manhg
sudo -u mongodb-manager /opt/mongodb-manager/.venv/bin/python -m web.manage --data-dir /var/lib/mongodb-manager-web configure-domain --url https://mongo.example.com
sudo cp /opt/mongodb-manager/deploy/mongodb-manager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mongodb-manager
sudo systemctl reload caddy
```

Chạy các lệnh `python -m web.manage` từ `/opt/mongodb-manager` để tìm được module `web`. Nếu user đã tồn tại thì bỏ qua lệnh `useradd`. Thư mục source/venv cần đọc và thực thi được bởi `mongodb-manager`. SSH key và `known_hosts` khi chạy service nằm trong home `/var/lib/mongodb-manager-web`; Local chạy bằng user này nên thao tác hệ thống cần cấu hình quyền riêng. Khóa và dữ liệu từ `.web-data` trên máy cá nhân không tự chuyển vào service trên VPS.

Với domain HTTPS, cookie được đánh dấu Secure và HSTS được bật. Uvicorn chỉ tin header proxy từ loopback; Caddy phải chạy cùng VPS với backend. Nếu dùng Cloudflare/proxy khác, cấu hình đường đi và trusted proxy tương ứng trước khi triển khai. Có thể trở về chế độ localhost bằng `configure-domain --url local`, rồi restart; tài khoản quản trị vẫn được giữ.

## Tiếp nhận cụm primary/secondary đang chạy

1. Vào **Máy chủ → Tiếp nhận cụm đang chạy** (hoặc nút **Thêm cụm**).
2. Nhập tên hiển thị, một endpoint `IP[:port]` của primary **hoặc secondary**, username/password MongoDB và auth database. Không nhập port sẽ dùng 27017; port tùy chỉnh cần nhập rõ. Để trống tên replica set để tự nhận diện. Tài khoản MongoDB khác với tài khoản SSH của VPS.
3. Bấm **Kiểm tra kết nối**: chỉ đăng nhập và đọc topology. Giao diện điền tên replica set và danh sách member quảng bá; không cài đặt, restart hay reconfigure cụm.
4. Bấm **Kiểm tra & lưu cụm**: chỉ lưu sau khi kiểm tra thành công. Mỗi replica set là một hồ sơ, không tạo một hồ sơ cho mỗi primary/secondary. Các replica set độc lập tạo hồ sơ riêng.
5. Ngay trong form tiếp nhận, mở **SSH cho các VPS trong cụm**, bấm **Thêm VPS bằng SSH** cho từng member, điền endpoint tương ứng, SSH host/port/user, password hoặc key, và tên service. **Kiểm tra & lưu cụm** lưu kết nối MongoDB cùng các hồ sơ SSH trong một transaction; SSH password được mã hóa và không trả lại trên API. Nếu MongoDB chưa kết nối được, chọn **Lưu SSH & mở máy chủ**, rồi bấm **Kiểm tra** ở VPS để chẩn đoán trước.
6. Hoặc để quản lý service/log/backup trên từng VPS sau này, thêm **Máy chủ** với SSH password/key, chọn **Thuộc cụm**, điền **Endpoint MongoDB trên VPS** và đúng **Tên service** đang dùng. Hồ sơ SSH không tự thay đổi membership.

Máy quản trị phải truy cập được tất cả địa chỉ MongoDB quảng bá, không chỉ seed vừa nhập. Nếu các member dùng IP private/hostname nội bộ, chạy manager trong cùng mạng/VPN hoặc bố trí đường mạng phù hợp; SSH vào một VPS không tự mở đường kết nối MongoDB tới mọi node.

## Primary thay đổi khi bầu chọn

Hồ sơ lưu **replica set + danh sách seed/member**, không gắn vai trò primary cố định vào VPS nào. Driver tìm primary hiện tại khi kết nối; chuỗi kết nối ứng dụng có nhiều seed và `replicaSet`. Khi thêm/bỏ member hoặc đọc trạng thái thành công, danh sách seed được cập nhật để lần kết nối sau vẫn tìm được cụm khi node ban đầu offline.

Tổng quan, Replica Set và trang phiên bản đọc lại trạng thái mỗi 10 giây khi đang xem, không mở hộp thao tác và tab đang hiển thị. Primary/Secondary là vai trò quan sát tại lần kiểm tra gần nhất. Lúc bầu chọn/mất quorum có thể tạm không tìm được primary; giao diện báo kết nối gián đoạn rồi kiểm tra lại. Lệnh quản trị có thể bị MongoDB từ chối nếu primary đổi đúng lúc thực hiện; tác vụ ghi không được tự gửi lại tùy tiện. Kiểm tra kết quả thực tế trước khi chạy lại.

VPS nguồn của wizard thêm Secondary chỉ dùng để đọc **keyfile**, có thể là primary hoặc secondary còn hoạt động. Nguồn này không phải “primary cố định”. SSH và service luôn tác động đúng VPS được chọn, dù vai trò MongoDB của VPS đó đã thay đổi. Ưu tiên/votes quyết định khả năng tham gia bầu chọn; node `priority=0` không thể thành primary. Nếu primary hỏng và không còn đủ phiếu, driver/giao diện không thể tự tạo quorum.

## VPS mới chưa có cụm

1. Thêm hồ sơ SSH trong **Máy chủ**, bấm **Kiểm tra** để đọc hệ điều hành, binary và service. Không tự coi “chưa thấy binary” là không có MongoDB chạy bằng container.
2. Chọn **Cài và tạo cụm mới**, chọn VPS, nhánh MongoDB, instance, replica set, port, endpoint quảng bá và tài khoản quản trị mới.
3. Xem lại đích rồi bấm **Thực hiện**. Worker kiểm tra port/thư mục, cài package nếu thiếu, tạo instance/keyfile/service riêng, khởi tạo một-node replica set và tạo user quản trị.
4. Hồ sơ cụm và liên kết VPS được lưu sau bootstrap; tác vụ kiểm tra thêm kết nối MongoDB từ máy quản trị. Nếu bước kết nối cuối thất bại, giữ lại hồ sơ để sửa firewall/địa chỉ rồi kiểm tra lại. Không chạy lại khởi tạo trên thư mục đã tạo.

Các nút cài package/setup riêng vẫn có để thực hiện theo từng bước khi cần. Cụm một node chưa có dự phòng trên máy khác.

## VPS mới thêm vào cụm hiện có

1. Tiếp nhận cụm đang chạy trước, thêm hồ sơ SSH của **VPS nguồn đang là member** và **VPS mới**.
2. Mở **Replica Set → VPS mới → Secondary** hoặc chọn thẻ tương ứng trong **Máy chủ**.
3. Chọn cụm, VPS đích, VPS nguồn, endpoint MongoDB nguồn, tên instance và endpoint quảng bá mới.
4. Backend kiểm tra nguồn thuộc cụm, đọc đường dẫn keyfile đang chạy bằng `getCmdLineOpts`, lấy keyfile qua SSH rồi chuyển trong bộ nhớ tới node mới. Không trả keyfile ra UI/API lịch sử. VPS nguồn cần quyền đọc keyfile qua root/`sudo -n`.
5. Cài package cùng nhánh 8.0/9.0 nếu thiếu, tạo service/thư mục trống và cấu hình cùng replSetName/keyfile. **Không chạy replSetInitiate hoặc tạo user riêng trên node mới**. Thêm member bằng reconfig thông thường và chờ SECONDARY tối đa 5 phút.
6. Chọn Votes và Ưu tiên ngay khi thêm node. Mặc định secondary dùng `votes=0`, `priority=0`. Khi đồng bộ ổn định, chỉnh votes/priority trong bảng member. MongoDB giới hạn số voting member; đừng tăng nhiều phiếu cùng lúc.

Wizard này dành cho keyfile không TLS, data directory mới. Node đã được chuẩn bị đúng cấu hình có thể dùng **Node đã chuẩn bị**; member đã thuộc cụm thì chỉ tiếp nhận hồ sơ, không thêm lại. Khi initial sync quá 5 phút, kiểm tra trạng thái hiện có trước khi thử lại. Nếu lỗi sau chuẩn bị service nhưng trước reconfig, sửa mạng rồi dùng **Node đã chuẩn bị**, tránh tạo lại instance.

## Máy thực thi và kết nối

- Cài đặt/setup dành cho Ubuntu LTS dùng systemd. Nhánh 8.0 kiểm tra gói cho 20.04, 22.04 và 24.04. Nhánh 9.0 kiểm tra gói cho 22.04, 24.04 và 26.04. Ubuntu 26.04 chọn 9.0, tối thiểu 9.0.4. Installer kiểm tra package thực có trên repository chính thức theo kiến trúc trước khi cài; từ chối cài đè khi đã có mongod.
- Chọn **Phiên bản & nâng cấp → Quản lý Ubuntu** để xem đường nâng theo từng chặng LTS. Với máy đang chạy MongoDB, kiểm tra bản sao lưu và xác nhận thời gian gián đoạn. Xem log và mở lại tác vụ trong **Lịch sử tác vụ** sau reboot.
- Máy SSH cần `python3`, mật khẩu SSH hoặc key/agent; thao tác hệ thống cần root hoặc `sudo -n`. Chọn phương thức trong hồ sơ máy: **Mật khẩu SSH** hoặc **SSH key / Agent**. Mật khẩu SSH được lưu mã hóa, không trả lại trên API/giao diện và không đưa vào dòng lệnh. Khi sửa hồ sơ, để trống mật khẩu để giữ nguyên; chuyển sang key/agent sẽ xóa mật khẩu SSH đã lưu. Xác thực mật khẩu dùng IP/hostname trực tiếp, không áp dụng alias/ProxyJump từ `~/.ssh/config`. Ở lần đăng nhập bằng mật khẩu đầu tiên, Manager tự lưu khóa VPS vào `~/.ssh/known_hosts` của tài khoản dịch vụ. Nếu khóa đã lưu thay đổi, Manager dừng trước khi gửi mật khẩu. Khi dùng key/agent, cần thêm khóa VPS vào `known_hosts` trước. Với tài khoản không phải root, tác vụ hệ thống vẫn cần `sudo -n`; mật khẩu SSH không được tự dùng làm mật khẩu sudo.
- Máy chạy web cần kết nối được tới mọi địa chỉ node MongoDB quảng bá. Máy SSH dùng cho dump/restore cũng cần kết nối được tới cụm.
- Tài khoản MongoDB cần quyền tương ứng: giám sát, quản lý cụm/user, backup/restore. Tạo backup/restore còn cần đọc `buildInfo` và FCV.
- TLS tùy chọn; mặc định dùng keyfile giữa các node và username/password cho client. Mở firewall đúng nguồn IP quản trị, ứng dụng và các member.
- Setup cho phép endpoint IP trực tiếp bằng `setParameter.disableSplitHorizonIPCheck=true`. Khi chuẩn bị node mở rộng, cấu hình tham số này trên các node thực hiện reconfiguration nếu dùng IP. Xem [tham số MongoDB chính thức](https://www.mongodb.com/docs/manual/reference/parameters/#mongodb-parameter-param.disableSplitHorizonIPCheck).
- Setup tạo service `mongod-manager-<instance>` và thư mục riêng dưới `/etc/mongodb-manager`, `/var/lib/mongodb-manager`, `/var/log/mongodb-manager`. Nếu bootstrap lỗi, log giữ lại đường dẫn để kiểm tra trước khi chạy lại.
- Chỉ bind web `127.0.0.1`. Khi chạy trên VPS, mở tunnel trên máy cá nhân: `ssh -L 8765:127.0.0.1:8765 user@vps`, rồi mở localhost. Web hỗ trợ một tài khoản quản trị, session phía server và CSRF. Chưa có phân quyền nhiều người dùng.

## Backup và restore

Backup nằm trên **máy thực thi đã chọn**, tại `/var/backups/mongodb-manager/<id>`, gồm các archive theo database (hoặc thư mục dump và oplog riêng với bản toàn replica set mới) và manifest SHA-256, nhánh MongoDB/FCV nguồn, phiên bản Database Tools. Backup toàn replica set dùng oplog, backup database/collection riêng không dùng oplog. Giữ nguyên FCV, phiên bản và cấu trúc dữ liệu trong suốt quá trình dump; backup riêng cần ứng dụng ngừng ghi nếu cần một ảnh chụp nhất quán.

Restore kiểm tra checksum và yêu cầu cùng nhánh MongoDB, cùng FCV. Chọn đúng máy chứa archive và đúng hồ sơ cụm đích; tùy chọn `drop` xóa collection đích trước khi restore. Nên restore thử vào cụm tách biệt và kiểm tra dữ liệu ứng dụng. Checksum chỉ kiểm tra file, không chứng minh khả năng phục hồi; giao diện luôn ghi rõ chưa restore thử. Bản restore toàn cụm có thể thay cả user/role theo nội dung archive.

## Mở rộng member và nâng cấp

**Node đã chuẩn bị / Thêm Arbiter** thực hiện reconfiguration trên cụm hiện có. Cần cùng replSetName/keyfile, bind/port, firewall phù hợp và service đang chạy. Wizard **VPS mới → Secondary** tự chuẩn bị các bước này cho node trống, trừ firewall. Các thao tác bỏ member/đổi bầu chọn kiểm tra quorum, từ chối gỡ primary trực tiếp.

Trang nâng cấp hiện thực hiện **kiểm tra điều kiện và hiển thị quy trình**, chưa tự chạy nâng major version. Quy trình: kiểm thử driver/ứng dụng; backup và restore thử; đối chiếu tài liệu đúng phiên bản; nâng secondary lần lượt, chờ healthy; step down primary rồi nâng node còn lại; kiểm thử ứng dụng; nâng FCV ở bước riêng theo tài liệu MongoDB. Không dùng tác vụ cài mới để nâng cụm đang chạy.

Tham khảo [cài Community Linux](https://www.mongodb.com/docs/manual/administration/install-community-linux/?linux-distro=ubuntu&linux-method=pkg) và [nâng replica set lên 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-from-8.0-replica-set/).

## Dữ liệu quản trị và giới hạn

`.web-data` chứa SQLite mã hóa các bản ghi, khóa `secret.key` và lịch sử tác vụ. Thư mục có quyền 0700, file 0600. Sao lưu cả database và key khi ứng dụng đã dừng; mất key sẽ không đọc lại được dữ liệu. Có thể đổi vị trí bằng biến `MONGO_MANAGER_DATA`. Không đưa thư mục này lên Git hay chia sẻ công khai.

Tác vụ chạy tuần tự. Khi backend dừng giữa chừng, tác vụ được đánh dấu gián đoạn ở lần mở sau; kiểm tra máy đích trước khi chạy lại. Đặt lịch theo từng workspace tại **Backup & restore → Các bản backup → Lịch backup**. Dịch vụ tự chạy lịch theo UTC+7. Chưa hỗ trợ hủy lệnh từ UI, chép backup qua SSH sang nơi thứ hai, sửa trực tiếp mongod.conf hoặc reset cụm. Không chạy đồng thời nhiều backend trên cùng thư mục dữ liệu.

Đã kiểm tra API, validation, mã hóa, quorum, SSH password thực với server thử local. Đã chạy MongoDB Community 8.0.16 và 9.0.7 thật trên macOS: tiếp nhận từ secondary của cụm hai member, xác minh dữ liệu/config không đổi, thêm node thứ ba với keyfile/auth và xác minh dữ liệu đồng bộ. Cài đặt apt/systemd trên Ubuntu, wizard chuẩn bị VPS mới qua SSH và backup/restore chưa được kiểm chứng end-to-end trên VPS thật. Xem `WEB_VALIDATION.md` để biết ranh giới kiểm thử.

## Kiểm tra mã

```bash
.venv/bin/python -m pytest tests/test_auth.py tests/test_web.py tests/test_ssh.py -q
MONGO_TEST_MONGOD=/absolute/path/to/mongod .venv/bin/python -m pytest tests/test_live_mongo.py -q
node --check web/static/app.js
bash -n start-web.sh
git diff --check
```

## Nhập SSH cho nhiều cụm cùng lúc

Vào **Cấu hình → SSH cho tất cả các cụm → Cấu hình SSH nhiều VPS**. Danh sách gồm mọi member từ các hồ sơ cụm, kể cả arbiter. Chọn các VPS dùng chung user/password hoặc key, nhập thông tin rồi lưu (tối đa 50 VPS mỗi lần). Hồ sơ SSH đã có giữ host/service riêng; hồ sơ thiếu được tạo và liên kết đúng endpoint/cụm. Password để trống chỉ giữ password đã lưu; VPS chưa có password phải nhập. Để chỉnh riêng một VPS, vào Máy chủ → Sửa.

Lưu chỉ thay credential trong bộ quản lý, không đổi password thật trên VPS. Mỗi VPS giữ credential của mình nên bầu chọn primary không làm thay thông tin SSH. Member mới thêm về sau cần cấu hình SSH riêng hoặc chạy lại màn hình áp dụng nhiều VPS.

Nút **Thêm node / Thêm Secondary** mở lựa chọn quy trình: cài/cấu hình VPS qua SSH (bao gồm kiểm tra, package, keyfile, service và đồng bộ), hoặc chỉ thêm membership cho node đã chuẩn bị. Nếu chưa lưu SSH VPS đích, chọn **Nhập SSH VPS mới**, lưu xong tự chuyển tới form chuẩn bị Secondary. Nhật ký luồng SSH chia sáu bước; lỗi endpoint đích chỉ rõ host và gợi ý kiểm tra cài đặt/service/firewall.

Luồng thêm member qua SSH hỗ trợ cả **Secondary** và **Arbiter**. Chọn vai trò trong form. Với **node đã chuẩn bị**, chọn chế độ tương ứng, nhập đường dẫn keyfile thực tế trên VPS để đối chiếu nguồn; ứng dụng kiểm tra binary/nhánh phiên bản, endpoint và replica set trước reconfig. Nếu mongod chưa cài, chuyển sang chế độ cài/cấu hình. Instance manager đã tạo và khớp replica set, port, bind, data path và keyfile được tái sử dụng; service dừng sẽ được khởi động lại. Instance không khớp hoặc binary khác nhánh sẽ bị chặn, không tự xóa dữ liệu/cài đè. Việc nâng/hạ phiên bản một instance đang có dữ liệu là quy trình riêng, không thuộc nút thêm node.
