// Translate UI labels only; hostnames, package versions and command output are data.
const englishLabels={
  'Quản trị VPS':'Server management','Hoạt động':'Activity','Giám sát':'Monitoring','Phát triển':'Development','Thiết lập VPS':'Server setup','Bảo mật':'Security',
  'Tài khoản & SSH':'Account & SSH','Tất cả':'All','Đã cài':'Installed','Hệ thống':'System','Cài đặt…':'Install…',
  'Mật khẩu Linux mới':'New Linux password','Nhập lại mật khẩu':'Confirm password','Hiện mật khẩu':'Show password',
  'Cho phép user này đăng nhập SSH bằng mật khẩu':'Allow SSH password login for this user',
  'Kiểm tra kết nối':'Test connection','Đường dẫn private key trên máy chạy Manager':'Private key path on the Manager host',
  'Tin cậy fingerprint và kết nối':'Trust fingerprint and connect','Không tìm thấy phần mềm.':'No matching packages.',
  'Gia hạn SSL':'Renew SSL','Gia hạn nếu đến hạn, kiểm tra cấu hình rồi reload Nginx.':'Renew if due, check configuration and reload Nginx.',
  'Máy chủ đích':'Target servers','Tác vụ nhiều máy':'Multi-server jobs','Đóng':'Close','Chọn ít nhất một máy chủ.':'Select at least one server.',
  'Chi tiết':'Details','Cấu hình':'Configuration','Nhật ký':'Logs','Chẩn đoán':'Diagnostics',
  'Lịch sử thay đổi':'Change history','Xem cú pháp':'Syntax highlighting','Kiểu website':'Website type',
  'Domain bổ sung':'Additional domains','URL chuyển hướng':'Redirect URL','Tùy chọn HTTP':'HTTP options',
  'Tạm dừng':'Pause','Tiếp tục':'Resume','Bật tự gia hạn':'Enable automatic renewal',
  'Chưa có bản sao từ editor.':'No editor backups yet.',
  'Không có lỗi cấu hình được ghi nhận.':'No configuration errors reported.',
  'Chưa tìm thấy log riêng trong cấu hình website.':'No readable log found for this website.',
  'Thêm tên miền':'Add domain','Đang bật':'Enabled','Đã tắt':'Disabled','Sửa':'Edit','Bật site':'Enable site','Tắt site':'Disable site','Thử gia hạn':'Test renewal','Cấp SSL':'Issue certificate','Xóa':'Delete','Xác thực':'Validation',
  'Chưa có tên miền do Manager quản lý.':'No domains managed by this application.',
  'Cài Certbot và plugin tương ứng trong Software Center trước khi cấp SSL.':'Install Certbot and the matching plugin in Software Center before requesting a certificate.',
  'Xóa cấu hình tên miền khỏi Nginx trên máy này?':'Remove this domain configuration from Nginx on this server?',
  'Tổng quan VPS':'VPS overview','Nginx & tên miền':'Nginx & domains','Lịch sử tác vụ':'Job history',
  'Tài khoản':'Username','Mật khẩu':'Password','Đăng nhập':'Sign in','Đăng xuất':'Sign out',
  'Máy chủ':'Server','Thêm VPS':'Add server','Hủy':'Cancel','Xác nhận':'Confirm',
  'Tạo tài khoản quản trị':'Create administrator','Lưu mã khôi phục':'Save recovery code',
  'Hệ điều hành':'Operating system','Kiến trúc':'Architecture','Ổ đĩa trống':'Free disk space',
  'Quản lý gói':'Package manager','Chưa có tác vụ.':'No jobs yet.','Chưa cài':'Not installed',
  'Thêm VPS để bắt đầu.':'Add a server to get started.','Đang đọc thông tin VPS…':'Reading server information…',
  'Preset web cơ bản':'Basic web preset','Xem kế hoạch cài':'Preview installation','Cài phần mềm':'Install software',
  'Tên máy':'Server name','Kiểu kết nối':'Connection type','Cổng SSH':'SSH port',
  'Mật khẩu SSH (để trống để dùng khóa SSH)':'SSH password (leave empty for SSH key)',
  'Xem thay đổi':'Preview changes','Áp dụng Nginx':'Apply Nginx configuration','Cổng ứng dụng trên VPS':'Application port on server',
  'Chọn ứng dụng PM2':'Select PM2 application'
};
const vpsEnglish=localStorage.getItem('mongo-manager-language')==='en';
function translateUI(root){
  if(!vpsEnglish)return;
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
  let node;
  while(node=walker.nextNode()){
    if(node.parentElement.closest('pre,code,#hosts,strong'))continue;
    const translated=englishLabels[node.textContent.trim()];
    if(translated)node.textContent=node.textContent.replace(node.textContent.trim(),translated);
  }
}
if(vpsEnglish){
  document.documentElement.lang='en';
  translateUI(document.body);
  new MutationObserver(changes=>{
    for(const change of changes)for(const node of change.addedNodes){
      if(node.nodeType===Node.ELEMENT_NODE)translateUI(node);
      else if(node.parentElement)translateUI(node.parentElement);
    }
  }).observe(document.body,{childList:true,subtree:true});
}
