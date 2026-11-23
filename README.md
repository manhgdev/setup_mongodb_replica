# MongoDB Manager

Giao diện web tiếng Việt và tiếng Anh để quản lý MongoDB Community. Từ một máy quản trị, bạn có thể tiếp nhận replica set đang chạy, cài cụm một node trên VPS Ubuntu mới, thêm secondary hoặc arbiter, theo dõi đồng bộ và quản lý backup.

## Chạy từ mã nguồn

Cần Python 3.10 trở lên với `venv` và pip. Mở terminal tại thư mục dự án và chạy:

```bash
./start-web.sh
```

Mở [MongoDB Manager trên máy này](http://127.0.0.1:8765). Nếu MongoDB Manager đã chạy, lệnh hiển thị URL rồi thoát thành công. Lần đầu, script tạo môi trường Python và cài các thư viện cần thiết. Giữ terminal mở khi sử dụng và nhấn `Ctrl+C` để dừng. Chọn **Xem thử giao diện** nếu muốn khám phá bằng dữ liệu minh họa.

### Chạy nền bằng PM2

Tại thư mục dự án, chạy `pm2 start pm2.start.json` rồi mở http://127.0.0.1:8765. Có thể đóng terminal sau khi chạy. Nếu đang chạy trực tiếp bằng `./start-web.sh`, chờ tác vụ hoàn tất rồi dừng phiên đó bằng Ctrl+C trước khi chuyển sang PM2.

- Xem trạng thái: `pm2 status mongodb-manager`
- Xem log: `pm2 logs mongodb-manager`
- Khởi động lại: `pm2 restart mongodb-manager`
- Dừng web: `pm2 stop mongodb-manager`

Để tạo tài khoản admin cho bản cài mới, chạy lệnh sau trong thư mục dự án sau khi đã tạo môi trường Python. Công cụ sẽ hỏi mật khẩu trong terminal:

```bash
.venv/bin/python -m web.manage create-admin --username admin
```

Để chạy trên VPS quản trị riêng, dùng `bash package-web.sh` để tạo gói `dist/mongodb-manager-web.tar.gz`. Các bước cấu hình tài khoản dịch vụ, tên miền và HTTPS có trong [hướng dẫn triển khai](README_WEB.md).

Trong collection ứng dụng, chọn **Thêm document**, hoặc mở document và nhấn trực tiếp vào giá trị cần sửa, kể cả trường con. Ô sửa dùng hết chiều rộng của trường và tự tăng chiều cao cho nội dung dài. Trong popup **Document**, nút **Lưu** nằm cạnh **Đóng** khi sửa một trường. Nhấn **Enter** hoặc **Lưu** để ghi, **Esc** để hủy. Có thể sửa toàn bộ document qua **Sửa JSON** hoặc chọn **Xóa**. Trình sửa nhận MongoDB Extended JSON. Khi thêm có thể bỏ `_id` để MongoDB sinh tự động. Khi sửa phải giữ nguyên `_id`. Tài khoản MongoDB cần quyền ghi tương ứng. Xóa cần xác nhận trong popup.

Trong **Dữ liệu**, nhấn F5 sẽ mở lại database, collection, bộ lọc, số document mỗi lượt tải và phần dữ liệu vừa tải của workspace hiện tại. Nhấn **Databases** để trở về danh sách.

## Chọn đúng thao tác

Mỗi trang hiển thị trực tiếp tên chức năng ở đầu trang. Chọn cụm một lần ở thanh bên. Các tác vụ trong workspace tự dùng cụm đang mở, kể cả backup, restore và thay đổi thành viên. Máy chủ mới được lưu vào workspace đang mở. Danh sách máy, lịch sử tác vụ và cấu hình SSH của workspace được lọc theo cụm. Nếu muốn cấu hình SSH cho nhiều cụm, mở **Các cụm MongoDB → SSH cho tất cả các cụm**. Màn hình xác nhận hiển thị đích trước khi chạy.

| Bạn đang có | Thao tác trong giao diện |
| --- | --- |
| Một cụm đã chạy | Vào **Các cụm MongoDB → Thêm cụm**. Nhập địa chỉ của primary hoặc secondary và tài khoản MongoDB có đủ quyền. Ứng dụng đọc danh sách member và nhận diện primary hiện tại. |
| Một VPS trắng để tạo cụm | Thêm hồ sơ VPS trong **Máy chủ**, chọn **VPS mới → Cụm mới**, rồi chọn phiên bản MongoDB, cổng, tên replica set và tài khoản quản trị. |
| Một VPS mới để mở rộng cụm | Chọn cụm → **Máy chủ → Thêm Secondary → Chuẩn bị qua SSH**. Chọn VPS nguồn giữ keyfile và VPS đích. Có thể để trống địa chỉ MongoDB của VPS mới và kiểm tra địa chỉ ứng dụng suy ra ở bước xem lại. |
| Một node đã chạy với đúng replica set và keyfile | Chọn **Thêm Secondary → Thêm qua MongoDB** và nhập endpoint của node. Nếu thêm arbiter, bắt đầu bằng **Thêm Arbiter**. |
| Một member cần gỡ | Vào **Máy chủ → Gỡ** ở cuối dòng secondary hoặc arbiter (hoặc **Replica Set → Gỡ**), mở thẳng **Xác nhận thao tác** cho node đã chọn. Bấm **Thực hiện** để gỡ hoặc **Hủy** để đóng. Với primary, chuyển vai trò trước khi gỡ. Thao tác này gỡ membership và giữ dữ liệu trên VPS. |

Trong **Máy chủ của bạn**, VPS thuộc replica set đứng trước, VPS chưa thuộc cụm xếp cuối bảng. Cột STT đánh số từ 1 theo thứ tự hiển thị trong từng bảng. **Xoá** xoá hồ sơ quản trị đã lưu. Nếu VPS còn thuộc replica set, nó xuất hiện trong **Thành viên chưa lưu hồ sơ máy**. **Gỡ** chỉ gỡ membership và giữ hồ sơ máy.

**Tài khoản MongoDB** dùng để đọc trạng thái, quản lý user và thay đổi cấu hình replica set theo quyền được cấp. **SSH** dùng cho tác vụ hệ điều hành như kiểm tra VPS, cài package, đọc keyfile và khởi động service. Hồ sơ SSH thuộc từng VPS nên vẫn dùng được khi cụm đổi primary.

## Backup & restore

Trong workspace nguồn, chọn **Backup & restore**. Máy thực thi lưu archive tại `/var/backups/mongodb-manager` và cần có MongoDB Database Tools. Máy này phải kết nối được tới các cụm dùng trong tác vụ.

- **Tạo backup** mặc định chọn tất cả database ứng dụng, bỏ qua admin, local và config. Có thể chọn toàn cụm, đánh dấu một hoặc nhiều database, hoặc chọn **Chọn collection trong database** rồi đánh dấu một hay nhiều collection theo tên. Trong **Dữ liệu**, nút **Backup collection** mở form với collection đang xem được chọn sẵn. Replica set toàn cụm có oplog. Các database được chọn được dump tuần tự, nên khi cần dữ liệu nhất quán giữa chúng hãy tạm dừng ghi hoặc dùng bản toàn replica set.
- Mở **Backup & restore** để tự đọc danh sách từ máy lưu trữ. Đổi **Máy lưu backup** nếu cần. Giao diện nhớ máy đã chọn theo từng workspace, kể cả sau F5. Mỗi bản hiển thị thời gian, ID backup đầy đủ, nguồn, phạm vi và dung lượng. Các nút Xem dữ liệu, Backup lại và Restore nằm cùng hàng. Trên màn hình hẹp, cuộn ngang trong bảng để xem các nút. Nếu danh sách rỗng, giao diện hiển thị tên máy, thư mục và nút tạo backup. Bản mới nhất đứng đầu. **Backup lại** tạo một bản mới cùng phạm vi từ nguồn đang mở và giữ các bản trước.
- Trong **Các bản backup → Lịch backup**, chọn máy lưu, phạm vi và tần suất, rồi nhấn **Lưu và bật lịch**. Mỗi workspace có một lịch, mặc định tắt. Có thể chọn mỗi giờ, hằng ngày, hằng tuần hoặc nhập cron 5 trường theo giờ Việt Nam (UTC+7). Ví dụ `0 2 * * *` chạy lúc 02:00 mỗi ngày. Trang hiển thị lần chạy kế tiếp. Mở lại cùng nút để sửa hoặc **Tạm dừng lịch**.
- Lịch được lưu trên máy quản trị và chạy khi dịch vụ MongoDB Manager hoạt động, kể cả khi đóng tab. Khi máy quản trị khởi động lại hoặc tác vụ khác đang bận, các kỳ đã lỡ được gộp thành một lần chạy khi rảnh. Mỗi lần chạy tạo một mục **Backup định kỳ** trong lịch sử tác vụ, kèm kết quả hoặc lỗi. Tạm dừng lịch có hiệu lực với các lần chạy tiếp theo.
- **Xem dữ liệu** mở trực tiếp nội dung đã sao lưu trên máy lưu trữ. Nhập một phần tên database hoặc collection vào ô tìm bên trái rồi chọn collection. Khi chọn xong, ô tìm được xóa để có thể nhấn ngay sang collection khác. Với bản sao một phần, nhóm **Từ bản backup khác** liệt kê thêm các collection cùng cụm nguồn trên máy lưu đang chọn. Collection có trong bản đang mở luôn dùng bản đó. Với collection bổ sung, giao diện dùng bản gần nhất có chứa collection và hiển thị thời điểm của bản đang đọc ở tiêu đề popup. Bảng bên phải hiển thị tối đa 25 document mỗi trang và 12 trường đầu để xem nhanh. Cuộn trong bảng theo hai chiều, dùng **Trước / Sau** để chuyển trang. Nhấn một dòng để đọc tất cả các trường, mở object hoặc array, hoặc xem **Extended JSON**. Nút **← Danh sách** quay lại đúng dòng đang đọc. Với bản toàn replica set, phần xem trước đọc dữ liệu dump trước bước replay oplog. Các collection hệ thống chứa thông tin nội bộ được ẩn.
- Cột kiểm chứng hiển thị số lần restore thành công qua Manager theo từng cụm đích, bao gồm cả đồng bộ. Lịch sử lấy từ nhật ký trên máy quản trị.
- **Restore** dùng đúng máy chứa bản sao trong danh sách. Nhấn Restore trên dòng để cố định ID. Trong **Restore vào**, chọn cụm để tìm primary tự động hoặc chọn tên máy và endpoint để ghi trực tiếp vào MongoDB tại đó. Máy nhận dùng tài khoản của hồ sơ MongoDB đã liên kết. Secondary và arbiter không nhận ghi trực tiếp. Sau khi gỡ member, mongod vẫn có thể chạy với replSetName và báo thiếu cấu hình replica set hợp lệ. Cần chuẩn bị một instance ghi được trước khi restore. Muốn restore thử riêng trên cùng VPS, dùng một instance độc lập ở cổng khác. Tất cả archive được kiểm tra checksum trước lần ghi đầu tiên. Nguồn và đích cần cùng nhánh phiên bản và FCV theo kiểm tra hiện tại của ứng dụng. Các bản cũ dạng một archive vẫn đọc được nếu có metadata tương thích.
- **Đồng bộ ngay** tạo backup mới rồi restore một lần vào một cụm MongoDB độc lập đã thêm trong **Các cụm MongoDB**. Primary và secondary cùng replica set tự sao chép dữ liệu. Để cập nhật collection đã có document trùng ID, chọn **Xóa collection đích trước khi restore** nếu muốn thay thế nội dung. Tùy chọn này có thể thay thế cả tài khoản khi restore database admin. Với bản toàn replica set, bước replay oplog kết nối lại sau khi restore tài khoản. Thông tin đăng nhập của hồ sơ đích phải còn hợp lệ ở thời điểm đó và có quyền replay oplog. Mặc định tùy chọn xóa tắt và mongorestore dừng khi gặp lỗi. Nếu restore dừng giữa chừng, một phần dữ liệu có thể đã được ghi. ID bản mới nằm trong nhật ký để có thể restore lại.

## Xem lại mật khẩu

Trong hồ sơ kết nối MongoDB và VPS SSH, nhấn biểu tượng mắt để xem mật khẩu đã lưu. Trong **User & phân quyền**, mật khẩu user được tạo hoặc đổi qua Manager được lưu mã hóa theo cụm, database xác thực và username. Với user có sẵn, chọn **Lưu mật khẩu** để nhập và xác thực mật khẩu hiện tại. Mật khẩu được che mặc định. Quản trị viên đã đăng nhập mới có thể xem lại. Mật khẩu đăng nhập web dùng cơ chế băm riêng, ô đăng nhập có nút mắt để kiểm tra ký tự đang nhập.

## Xem dữ liệu

Trang **Dữ liệu** dùng cùng kiểu tiêu đề với các trang quản trị khác, có mô tả bên dưới và nút **Làm mới** ở phần đầu trang.

Trong workspace của cụm, mở **Dữ liệu → Collections** trên dòng database. Nút **«** ở cuối menu trái và cuối cột Collections thu gọn từng panel. Nhấn **»** ở cùng vị trí để mở lại. Khi hai khung nằm cạnh nhau, kéo đường chia sang trái hoặc phải để chỉnh độ rộng. Trình duyệt ghi nhớ tỉ lệ đã chọn. Cũng có thể nhấn Tab đến đường chia và dùng phím ← hoặc →. Chọn collection ở cột bên trái để đọc document, mở từng object hoặc mảng để xem trường con, hoặc chọn **Extended JSON** để đọc document kèm kiểu dữ liệu BSON. Chọn **Bảng gọn** để xem mỗi document trên một dòng với cột STT liên tục khi cuộn, bấm trực tiếp vào dòng (hoặc dùng Enter) để đọc đủ các trường, hoặc chuyển sang **Chi tiết**. Trong **Bảng gọn**, cuộn ngang ngay trong khung Documents để xem các cột bên phải. Các trường mới xuất hiện ở lượt tải sau được thêm vào cuối bảng. Cuộn dọc trong khung để tải tiếp. Mỗi lượt tải tối đa 25 document, có thể giảm xuống 5 hoặc 10. Thanh phân trang phía trên khung có số trang và nút **Trước / Sau**. Trang đang chọn cập nhật khi cuộn. Dòng mới nối vào cuối khung và giữ nguyên các dòng trước đó để cuộn ngược lên. Mở **Indexes** để xem index của collection. Khi thu gọn menu trái hoặc danh sách Collections, các biểu tượng vẫn bấm được. Di chuột lên biểu tượng để xem tên.

Bộ lọc so sánh bằng theo tên trường, hỗ trợ đường dẫn như `metadata.sequence`. Nhập giá trị dạng JSON, ví dụ `42`, `true`, `"active"`, hoặc Extended JSON như `{"$oid":"507f1f77bcf86cd799439011"}` cho ObjectId. Tài khoản MongoDB cần quyền đọc trên collection muốn xem.

## Dùng sơ đồ và quản lý bầu chọn

Nhãn vai trò dùng chung màu trên sơ đồ và các bảng: PRIMARY xanh lá, SECONDARY xanh dương, ARBITER tím. Nhãn Votes · Ưu tiên dùng cùng màu vai trò và cùng kích thước trên các dòng máy chủ. Trạng thái khởi động hoặc phục hồi dùng màu hổ phách.

- Trong **Tổng quan cụm**, bấm thẻ trạng thái để mở chẩn đoán, thẻ thành viên để quản lý máy, độ trễ để xem replica set hoặc backup để quản lý bản sao. Các dòng phiên bản, phiếu, xác thực và TLS cũng mở trang tương ứng trong workspace hiện tại.
- Trong **Tổng quan → Sơ đồ replica set**, bấm vào thẻ node để mở đúng dòng ở **Máy chủ**. Nhấp đúp vào tên để đổi tên hiển thị. Tên này được lưu trong trình duyệt. IP và cổng MongoDB hiển thị ngay trên thẻ node và dưới tên máy trong bảng. Cột Kết nối hiển thị riêng user, địa chỉ và cổng SSH.
- Trong **Máy chủ**, bấm **Kiểm tra** để chạy kiểm tra môi trường trên VPS đã chọn. Member chưa có hồ sơ SSH có nút **Cấu hình SSH**.
- Khi thêm secondary qua MongoDB hoặc SSH, chọn **Votes** và **Ưu tiên bầu primary** ngay trên biểu mẫu. Nếu giữ mặc định, secondary có **Votes = 0, Priority = 0** và vẫn sao chép dữ liệu. Trang **Máy chủ** hiển thị **Votes** và **Ưu tiên** cạnh nhau trên dòng member. Sau khi node đã khỏe, bấm vào hai giá trị này để chỉnh. **Votes = 1** cho phép bỏ phiếu. **Priority > 0** cho phép secondary đủ điều kiện ứng cử primary.
- Nút **Đổi primary** màu xanh lá nhạt nằm ở góc phải tiêu đề **Máy chủ của bạn** (hoặc **Replica Set → Step down Primary → Xem trước**) mở thẳng **Xác nhận thao tác** cho cụm đang chọn. Chọn **Primary mong muốn** hoặc **Để MongoDB tự bầu**, rồi bấm **Thực hiện**. Khi chỉ định node, ứng dụng cho phép node đích ứng cử ngay, tạm hoãn ứng cử trên các secondary đủ điều kiện khác trong 45 giây, yêu cầu primary hiện tại bàn giao sau khi đồng bộ và kiểm tra đúng endpoint đã trở thành primary. Theo dõi kết quả trong sơ đồ hoặc bảng thành viên.

## Mã nguồn và tài liệu

| Vị trí | Nội dung |
| --- | --- |
| [web/](web/) | Backend FastAPI, kết nối MongoDB, thực thi trên VPS và giao diện web |
| [menu.sh](menu.sh) | Menu Bash để thao tác trực tiếp trong terminal |
| [deploy/](deploy/) | Mẫu systemd và Caddy cho máy quản trị |
| [previews/](previews/) | Ảnh chụp giao diện |
| [tests/](tests/) | Kiểm thử API, xác thực, SSH và replica set |
| [README_WEB.md](README_WEB.md) | Hướng dẫn chi tiết về SSH, cài đặt, backup, restore và triển khai |
| [WEB_VALIDATION.md](WEB_VALIDATION.md) | Các lần kiểm chứng thực tế và phạm vi đã thử |

Hồ sơ quản trị mặc định nằm trong `.web-data/`. Khi sao lưu hoặc chuyển ứng dụng sang máy khác, giữ cả cơ sở dữ liệu và khóa mã hóa của thư mục này.

## Cập nhật tài liệu

Mỗi lần sửa dự án, cập nhật README này trong cùng thay đổi. Nếu thay đổi ảnh hưởng đến cách sử dụng, sửa trực tiếp hướng dẫn tương ứng. Với bản sửa nội bộ, ghi ngắn gọn nội dung và cách kiểm tra ở mục dưới. Đặt ảnh giao diện mới trong `previews/`.

### Thay đổi gần đây

- Khi chọn primary, ứng dụng chờ secondary áp dụng tới mốc oplog lấy từ primary trước khi yêu cầu bầu. Primary cũ nhường vai trò bằng step-down có kiểm tra đồng bộ. Secondary khác vẫn bỏ phiếu trong thời gian tạm hoãn ứng cử.

- **23/11/2026** — Khi xem lại tác vụ, kiểm tra tên cụm hoặc VPS rồi bấm **Thực hiện**. Không cần gõ lại tên đích.

- **23/11/2026** — Gom ảnh giao diện vào `previews/`. Sơ đồ hiển thị đủ member và cho mở đúng VPS bằng một lần bấm. Trường Votes dùng bộ chọn 0 hoặc 1.
- **23/11/2026** — Sau khi tác vụ kết thúc, trang hiện tại tự đọc lại dữ liệu. Trang Máy chủ cập nhật topology định kỳ. Khi có bản giao diện mới, tab tự tải lại khi đang hiển thị và đã đóng biểu mẫu.

- Xác nhận xoá hồ sơ máy và cụm bằng popup trong ứng dụng. Bấm **Hủy** hoặc **Esc** để quay lại.
