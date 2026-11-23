"""Local-only administrator setup. Password is read from a hidden terminal prompt."""
import argparse
import getpass
import os
import re
import tempfile
from pathlib import Path

from .auth import password_hash, private_json, public_origin


def main():
    parser = argparse.ArgumentParser(description='Cấu hình MongoDB Manager trên máy chạy ứng dụng')
    parser.add_argument('--data-dir', default=os.environ.get('MONGO_MANAGER_DATA', str(Path(__file__).resolve().parent.parent / '.web-data')))
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('init-admin', help='Khởi tạo tài khoản mặc định khi chưa có admin')
    admin = sub.add_parser('create-admin')
    admin.add_argument('--username', required=True)
    admin.add_argument('--replace', action='store_true', help='Đặt lại tài khoản và vô hiệu hóa các phiên cũ sau khi restart')
    domain = sub.add_parser('configure-domain')
    domain.add_argument('--url', required=True, help='https://mongo.example.com; dùng local để trở về localhost')
    args = parser.parse_args()
    directory = Path(args.data_dir).expanduser().resolve()
    if args.command == 'init-admin':
        path = directory / 'admin.json'
        if path.exists():
            return
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        template = Path(__file__).resolve().parent.parent / 'deploy' / 'initial-admin.json'
        with tempfile.NamedTemporaryFile(dir=directory) as output:
            output.write(template.read_bytes())
            output.flush()
            try:
                os.link(output.name, path)
            except FileExistsError:
                pass
        return
    if args.command == 'create-admin':
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', args.username):
            parser.error('Username chỉ gồm chữ, số, dấu chấm, gạch ngang hoặc gạch dưới.')
        path = directory / 'admin.json'
        if path.exists() and not args.replace:
            parser.error('Tài khoản đã tồn tại. Dùng --replace khi chủ động đặt lại.')
        password = getpass.getpass('Mật khẩu quản trị: ')
        if len(password) < 6 or len(password) > 1000:
            parser.error('Mật khẩu cần từ 6 đến 1000 ký tự.')
        if getpass.getpass('Nhập lại mật khẩu: ') != password:
            parser.error('Hai lần nhập chưa khớp.')
        private_json(path, {'username': args.username, 'password_hash': password_hash(password)})
        print('Đã tạo tài khoản quản trị. Khởi động lại ứng dụng để áp dụng.')
    else:
        origin = '' if args.url == 'local' else public_origin(args.url)
        if origin and not (directory / 'admin.json').exists():
            parser.error('Tạo tài khoản quản trị trước khi cấu hình domain.')
        private_json(directory / 'deployment.json', {'public_url': origin})
        print('Đã lưu chế độ ' + (origin or 'localhost') + '. Khởi động lại ứng dụng để áp dụng.')


if __name__ == '__main__':
    main()
