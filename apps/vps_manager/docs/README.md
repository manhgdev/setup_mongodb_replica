# ZM VPS Manager

Nhấn **ZM VPS Manager ↗** trên thanh trên cùng để mở giao diện VPS. Nút **← MongoDB Manager** đưa bạn về màn hình trước. Chọn VPS hiện có hoặc thêm máy qua SSH/local. Tài khoản SSH cần có khóa máy chủ đã xác minh trong known_hosts của user chạy web. Tác vụ đặc quyền qua SSH dùng root hoặc sudo không tương tác.

- **Tổng quan VPS** đọc OS, kiến trúc, CPU, RAM, ổ đĩa và trạng thái Nginx trực tiếp trên máy.
- **Software Center** mở toàn bộ mục trong bộ cài cá nhân. `manifests/kits.json` quy định thành phần mỗi bộ; danh sách **Tất cả** lấy trực tiếp từ manifest gói. Mở **Công cụ VPS** để tra kho hoặc liệt kê gói hệ điều hành.
- **Docker & Compose** dùng bộ Docker để cài Engine và plugin từ kho APT/DNF đã cấu hình, kiểm tra daemon riêng. Worker chạy Docker CLI qua socket trên VPS. Có thể xem log, đổi trạng thái container hoặc kiểm tra và triển khai file Compose hiện có. Manager ghi tác vụ thay đổi vào lịch sử. [Container trên VM Ubuntu](../../../previews/vps-manager/docker-containers.jpg).
- **Firewall** hợp nhất UFW và Oracle Cloud Firewall (OCI SDK, xác thực API Key hoặc Instance Principal). Xem [README chính](../../../README.md) để biết quyền IAM và cách mở port đồng thời hai lớp.
- **Nginx & tên miền** đọc các site do Manager tạo trên VPS. Thêm domain với cổng localhost hoặc chọn ứng dụng PM2 có biến PORT. Mỗi site có thao tác sửa cổng, bật, tắt, xóa và cấp SSL. Tắt site chuyển cấu hình từ `/etc/nginx/conf.d/` sang `/etc/nginx/zm-disabled/`. Manager lưu bản sao cấu hình vào `/etc/nginx/zm-backups/`, kiểm tra `nginx -t`, reload và khôi phục cấu hình khi áp dụng thất bại. Xóa site giữ lại chứng chỉ trên VPS.
- **Cấp SSL** cần cài Certbot và plugin trong Software Center. Chọn plugin Nginx cho HTTP-01 khi tên miền trỏ về VPS và cổng 80 truy cập được từ Internet. Chọn plugin Cloudflare cho DNS-01, nhập email và token có quyền `Zone:DNS:Edit` cho zone đó. Plugin dùng tệp `/etc/letsencrypt/zm-credentials/<domain>.ini` (quyền 0600) trên VPS để gia hạn. Sau khi cấp thành công, site phục vụ cả HTTP và HTTPS. Nút **Thử gia hạn** chạy Certbot dry-run cho đúng chứng chỉ. Lịch gia hạn do gói Certbot của hệ điều hành cung cấp. [Tài liệu Certbot Cloudflare](https://certbot-dns-cloudflare.readthedocs.io/en/stable/).

![Quản lý tên miền Nginx](../../../previews/vps-manager/nginx-domains.jpg)

- **Lịch sử tác vụ** hiển thị job từ hai ứng dụng trên máy đã chọn. Mở job để đọc log và kết quả.

![Software Center](../../../previews/vps-manager/software-my-kits.jpg)

Chạy riêng với hai thư mục `apps/vps_manager/` và `shared/manager_core/` tại gốc checkout.

```bash
python3 -m venv .venv
.venv/bin/pip install -r apps/vps_manager/requirements.txt
.venv/bin/python -m uvicorn apps.vps_manager.backend.app:create_app --factory --host 127.0.0.1 --port 8765
.venv/bin/python -m pytest apps/vps_manager/tests
```

URL mặc định là `/vps/`. Đặt `ZM_MONGO_URL` để đổi đích chuyển sang MongoDB Manager. Khi vận hành hai tiến trình độc lập, chọn thư mục dữ liệu riêng qua `MONGO_MANAGER_DATA`. Chạy gateway để chia sẻ session và khóa tác vụ trong cùng tiến trình.

### Website đã có trên VPS

Mở **Nginx & tên miền → Chi tiết** để xem cấu hình, listener, SSL, nhật ký, chẩn đoán và lịch sử sửa file. Inventory đọc kết quả `nginx -T` cùng các thư mục site đã tắt. Khi Nginx báo lỗi, màn hình hiện thông báo kiểm tra cấu hình và tiếp tục dò file trên đĩa. Trạng thái bật cho biết cấu hình có trong chuỗi include.

Form tạo hỗ trợ static, PHP-FPM, redirect, reverse proxy, WebSocket, SSE và gRPC. Với upstream nhiều máy, phân tách đích bằng dấu phẩy, ví dụ `127.0.0.1:3000 weight=2, 127.0.0.1:3001 backup`. Có thể chọn Unix socket PHP-FPM và thêm header, gzip, cache proxy, CORS, whitelist, rate limit hoặc đường dẫn htpasswd. Khi cấp SSL cho site của Manager, nhập các tên bổ sung vào cùng chứng chỉ. Tên wildcard cần xác thực DNS Cloudflare.

Editor áp dụng theo **file**. Popup diff liệt kê các domain trong file trước khi lưu. Mở **Lịch sử thay đổi** để xem diff và khôi phục bản trước. Editor chỉnh các file site đang được include trong `sites-available` và `conf.d` có cấu trúc cấp ngoài là server/upstream. Nhật ký hiển thị phần cuối của file văn bản dưới `/var/log/nginx/`; số đếm HTTP status tính trên các dòng đang hiển thị và có thể bao gồm nhiều website chung log.

![Danh sách website trên VPS](../../../previews/vps-manager/nginx-inventory.jpg)


### Tài khoản Linux và SSH

Hồ sơ SSH key có thể dùng khóa mặc định hoặc đường dẫn private key thuộc tài khoản chạy Manager. Đối chiếu fingerprint hiển thị khi kiểm tra kết nối với fingerprint trong console của VPS trước khi tin cậy. User mới cần sudo không tương tác để thay đổi mật khẩu qua Manager. Tùy chọn mặc định chỉ đặt mật khẩu cho tài khoản Linux. Tùy chọn bật SSH password áp dụng cho user đã xác minh. Manager ghi nhận từng bước vào lịch sử tác vụ và vẫn dùng key cho hồ sơ.

Khi cần thay đổi chính sách SSH, worker sao lưu sshd_config dưới /run/zm-manager-ssh, đặt timer rollback 150 giây và kiểm tra chính sách trước khi reload. Manager mở phiên mới bằng key và mật khẩu để xác minh. Nếu mất kết nối ở bước này, xem trạng thái lại sau thời hạn rollback. Mật khẩu Linux vừa đặt vẫn có hiệu lực khi cấu hình SSH được phục hồi.

![Tài khoản và SSH](../../../previews/vps-manager/account-ssh.jpg)


### Danh mục cài đặt

Mục **Bộ cài của tôi** đọc tên hiển thị, nhóm, tên gói theo APT/DNF và hướng dẫn cài từ manifest của ứng dụng. Nhập tên gói hoặc chọn nhóm để lọc. Bộ cài là lựa chọn ban đầu, có thể bỏ hoặc thêm từng mục trước khi xác nhận.

| Nhóm | Thành phần |
|---|---|
| Công cụ VPS | GCC, G++, Make, Git, curl, wget, unzip, zip, Vim, tmux, jq, rsync |
| Giám sát và mạng | htop, btop, ncdu, vnStat, net-tools, dnsutils, lsof, cron, netcat, logrotate, Speedtest CLI, Bench.sh |
| Python và Go | Python 3, pip, venv, lệnh python, pip/setuptools/wheel trong venv, Go từ kho hệ điều hành hoặc PPA longsleep của Ubuntu |
| Node.js | NVM, Node LTS và npm, Bun, Yarn, fast-cli, NSS, ALSA, PM2, PM2 startup/save, PM2 Logrotate 100M/3 bản/nén |
| Media | FFmpeg, libavcodec-extra, aria2, yt-dlp stable/nightly và timer cập nhật nightly lúc 08:00 theo múi giờ VPS |
| Web, SSL và bảo mật | Nginx, UFW, Fail2ban, OpenSSL, CA certificates, Certbot qua kho gói/Snap/venv, plugin Nginx/Apache/Cloudflare và timer gia hạn |
| Database và thiết lập | Redis, bật dịch vụ Redis/Nginx/vnStat/cron/Fail2ban, múi giờ Asia/Ho_Chi_Minh |

**Tài khoản cài đặt.** NVM, Node, npm global, Bun, PM2, Bench.sh và Python venv của người dùng chạy dưới user của hồ sơ SSH. Venv ở `~/.venvs/zm-vps`. Hai bản yt-dlp có tên `yt-dlp` và `yt-dlp-nightly` trong `/usr/local/bin`. Bench.sh được tải về `~/.local/bin/bench.sh` để chạy khi cần đo hiệu năng. Bộ cài kiểm tra từng dependency và phiên bản sau khi cài. Trên Ubuntu, thư viện âm thanh tự chọn tên gói có trong kho, gồm `libasound2` hoặc `libasound2t64`.

**Bảo trì gói.** Chọn VPS, mở popup bảo trì và xác nhận thao tác cập nhật danh mục, nâng các gói hệ thống, làm mới CA hoặc cài lại OpenSSL và CA. Giao diện **Nginx & tên miền** quản lý cấu hình website và chứng chỉ. Thao tác mở port, sửa DNS, swap, TCP/nofile và xóa dữ liệu được tách khỏi bộ cài phần mềm.

## Git & SSH Key

Chọn VPS rồi mở **Git & SSH Key**. **Cài công cụ / Cập nhật** sử dụng kho APT đã cấu hình để cài hoặc nâng `git` và `openssh-client`. **Sửa danh tính** ghi Git Username và Git Email vào cấu hình global của user Linux đang kết nối.

- **+ Tạo SSH key** tạo ED25519 mặc định hoặc RSA 4096-bit. Có thể nhập email và passphrase. Private key nằm trên VPS, thư mục SSH dùng quyền `0700` và private key dùng `0600`. Manager từ chối tên file đã tồn tại.
- Danh sách đọc các file public key `~/.ssh/*.pub`. Với private key thiếu file `.pub`, chọn **Tạo lại public key** rồi nhập passphrase nếu có. **Nhập public key** lưu một public key độc lập. Để xác thực Git, VPS cần có private key tương ứng. Bấm **Public key → Sao chép**, sau đó mở **GitHub Keys ↗** hoặc trang SSH keys của GitLab/Bitbucket để đăng ký.
- **+ Alias** gắn một host, ví dụ `github-work`, với provider và key đã chọn trong `~/.ssh/config`. Dùng `git clone git@github-work:nhom/project.git` hoặc đặt remote URL dùng alias đó. Các alias dùng agent riêng qua `IdentityAgent`. Key mới tự nạp vào agent. Sau reboot, chọn **Nạp vào agent** và nhập lại passphrase nếu có.
- **Kiểm tra kết nối** dùng key đã chọn và đối chiếu host key ED25519 trước khi xác thực qua cổng 22. Nếu provider đổi fingerprint, cập nhật giá trị đã đối chiếu với tài liệu của họ. [GitHub](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/testing-your-ssh-connection) · [GitLab](https://docs.gitlab.com/user/gitlab_com/) · [Bitbucket](https://support.atlassian.com/bitbucket-cloud/docs/configure-ssh-and-two-step-verification/).
- **Gỡ alias** giữ lại file key. **Xóa key** yêu cầu xác nhận, gỡ key khỏi agent của Manager, xóa các file của key và alias do Manager quản lý trên VPS. Việc thu hồi public key đã đăng ký ở nhà cung cấp Git thực hiện trong tài khoản của nhà cung cấp.
- **Lịch sử tác vụ** hiển thị từng bước, kết quả và lỗi. Passphrase chỉ được chuyển đến worker để thực hiện tác vụ.

![Danh tính Git, SSH key và alias trên VPS Ubuntu](../../../previews/vps-manager/git-ssh-keys.jpg)
