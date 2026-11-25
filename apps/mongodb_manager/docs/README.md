# MongoDB Manager

Quản lý replica set, máy thực thi, backup, dữ liệu và nâng cấp MongoDB trong [sổ tay theo màn hình](../../../README.md#manual). Các ảnh nằm tại [previews/mongodb-manager](../../../previews/mongodb-manager/).

Để chạy độc lập, giữ cấu trúc `apps/mongodb_manager/` và `shared/manager_core/` từ gốc checkout.

```bash
python3 -m venv .venv
.venv/bin/pip install -r apps/mongodb_manager/requirements.txt
.venv/bin/python -m uvicorn apps.mongodb_manager.backend.app:app --host 127.0.0.1 --port 8765
```

Dữ liệu cũ vẫn ở `.web-data/`. Biến `MONGO_MANAGER_DATA` chọn thư mục khác. Đặt `ZM_VPS_URL` để trỏ nút chuyển ứng dụng tới một bản VPS Manager ở địa chỉ riêng. Dùng một tiến trình gateway khi cả hai ứng dụng vận hành cùng kho dữ liệu. Chạy kiểm thử bằng `.venv/bin/python -m pytest apps/mongodb_manager/tests`.
