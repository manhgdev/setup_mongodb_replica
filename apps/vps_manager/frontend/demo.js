// All VPS API calls in preview mode terminate here, including unsupported operations.
let sampleCatalog;
async function previewVps(path,data){
  const machine='vps/machines/demo';
  const route=path.split('?')[0];
  const domain='web.example.test';
  const source='/etc/nginx/sites-available/'+domain;
  const site={domain,primary:domain,source,file_id:'web',kind:'proxy',target:'127.0.0.1:3000',listeners:['443'],https:true,enabled:true,managed:false,expires:64,renewal_names:[domain]};
  if(!data){
    switch(route){
      case 'vps/machines':return [{id:'demo',name:'Ubuntu VPS · Demo'}];
      case machine:{
        sampleCatalog ||= await api('vps/catalog');
        return {...sampleCatalog,host:'web-demo',os:'Ubuntu 24.04 LTS',arch:'amd64',cpu:4,memory:'8 GiB',disk_total:80*2**30,disk_used:32*2**30,memory_total:8*2**30,memory_available:5*2**30,load_average:[0.38,0.46,0.42],kernel:'6.8.0-generic',uptime_seconds:896400,disk_free:48*2**30,nginx:'active',manager:'apt',
        top_processes:[{pid:1220,user:'root',name:'node',cmd:'node /home/api_express/src/index.js',cpu:3.4,mem:1.8,rss:148*1048576,time:'02:40.66'},{pid:842,user:'mongodb',name:'mongod',cmd:'/usr/bin/mongod --config /etc/mongod.conf',cpu:1.9,mem:4.2,rss:340*1048576,time:'01:12.30'},{pid:510,user:'www-data',name:'nginx',cmd:'nginx: worker process',cpu:0.4,mem:0.3,rss:24*1048576,time:'00:05.12'},{pid:1089,user:'root',name:'PM2',cmd:'PM2 v7.1.2: God Daemon (/root/.pm2)',cpu:0.2,mem:1.1,rss:88*1048576,time:'00:09.67'}],
        packages:{...Object.fromEntries(Object.keys(sampleCatalog.catalog).map(id=>[id,''])),git:'2.43.0',nginx:'1.24.0',curl:'8.5.0','docker-engine':'Docker 28 (demo)','docker-service':'active','docker-compose':'2.40 (demo)'}};}
      case machine+'/git/status':return {git:'git version 2.43',ssh:'OpenSSH 9.6',username:'Demo',email:'demo@example.test',keys:[],aliases:{}};
      case machine+'/docker/status':return {engine:true,active:true,compose:'2.40 (demo)',containers:[{ID:'a'.repeat(64),Names:'web-demo',State:'running',Status:'Up · demo',Image:'nginx:alpine',Ports:'127.0.0.1:8080 → 80'}]};
      case machine+'/firewall':return {ufw:{installed:true,active:true,error:'',rules:[]},ssh_ports:[22],listening:[],oracle:{detected:true,region:'ap-singapore-1',shape:'VM.Standard.A1.Flex',instance_id:'ocid1.instance.oc1..demo'},accounts:[{id:'demo',name:'Demo',auth:'api_key',region:'ap-singapore-1'}],link:{account_id:'demo',account:'Demo',region:''},oci_error:'',
        oci:{instance:{id:'ocid1.instance.oc1..demo',name:'web-demo',state:'RUNNING'},vnics:[{id:'ocid1.vnic.oc1..demo',private_ip:'10.0.0.12',public_ip:'203.0.113.10',vcn:{name:'vcn-demo',cidr:'10.0.0.0/16'},subnet:{name:'public',cidr:'10.0.0.0/24'},security_lists:[{id:'sl',name:'Default',rules:[]}],nsgs:[]}]},
        rows:[{proto:'tcp',min:22,max:22,listening:[{port:22,process:'sshd',local_only:false}],internal:true,external:'open',ufw:'open',oci:'open',warnings:[]},{proto:'tcp',min:80,max:80,listening:[{port:80,process:'nginx',local_only:false}],internal:true,external:'closed',ufw:'open',oci:'closed',warnings:['oci_blocked']},{proto:'tcp',min:443,max:443,listening:[{port:443,process:'nginx',local_only:false}],internal:true,external:'open',ufw:'open',oci:'open',warnings:[]}]};
      case 'vps/servers':return [{id:'demo',name:'Ubuntu VPS · Demo',mode:'ssh',host:'203.0.113.10',port:22,user:'root',ssh_auth:'password',has_ssh_password:true,mongo_endpoint:'203.0.113.10:27017'}];
      case machine+'/docker/logs':return {text:'web-demo · GET / 200'};
      case machine+'/docker/plan':return {project:'web-demo',services:[{name:'web',image:'nginx:alpine'}],revision:'demo'};
      case machine+'/metrics':{
        return {cpu:4,disk_free:82*2**30,disk_total:120*2**30,disk_used:38*2**30,memory_total:8*2**30,memory_available:3.9*2**30,uptime_seconds:984200,load_average:[0.28,0.25,0.18],top_processes:[{pid:1220,user:'root',name:'node',cmd:'node /home/api_express/src/index.js',cpu:3.4,mem:1.8,rss:148*1048576,time:'02:40.66'},{pid:842,user:'mongodb',name:'mongod',cmd:'/usr/bin/mongod --config /etc/mongod.conf',cpu:1.9,mem:4.2,rss:340*1048576,time:'01:12.30'},{pid:510,user:'www-data',name:'nginx',cmd:'nginx: worker process',cpu:0.4,mem:0.3,rss:24*1048576,time:'00:05.12'},{pid:1089,user:'root',name:'PM2',cmd:'PM2 v7.1.2: God Daemon (/root/.pm2)',cpu:0.2,mem:1.1,rss:88*1048576,time:'00:09.67'}]};
      }
      case machine+'/packages':{
        const params=new URL(path,location.origin).searchParams;
        const installed=params.get('scope')==='installed';
        const items=(installed?['curl','git','nginx']:['curl','git','nginx','tree','zip']).filter(name=>name.includes(params.get('query')||'')).map(name=>({name,version:installed?'1.0 (demo)':''}));
        return {total:items.length,items};
      }
      case machine+'/package-plan':{
        const name=new URL(path,location.origin).searchParams.get('name');
        return {target:name,summary:vpsEnglish?'Preview only':'Kế hoạch minh họa'};
      }
      case machine+'/account':return {user:'ubuntu',host:'web.example.test',port:22,sudo:true,auth:'key',password:'no'};
      case machine+'/sysadmin':return {
        users:[
          {username:'root',uid:0,gid:0,home:'/root',shell:'/bin/bash',groups:['root'],sudo:true,nopasswd:true,locked:false,ssh_keys:[],ssh_key_count:0,is_current:false},
          {username:'ubuntu',uid:1000,gid:1000,home:'/home/ubuntu',shell:'/bin/bash',groups:['ubuntu','sudo','docker'],sudo:true,nopasswd:true,locked:false,ssh_keys:['ssh-ed25519 AAAA... demo@mac'],ssh_key_count:1,is_current:true},
          {username:'deploy',uid:1001,gid:1001,home:'/home/deploy',shell:'/bin/bash',groups:['deploy','www-data'],sudo:false,nopasswd:false,locked:false,ssh_keys:[],ssh_key_count:0,is_current:false}
        ],
        groups:['adm','deploy','docker','sudo','ubuntu','www-data'],
        disks:[
          {name:'sda',path:'/dev/sda',size:53687091200,type:'disk',fstype:'',mountpoint:'',model:'Oracle BlockVolume',protected:true,children:[
            {name:'sda1',path:'/dev/sda1',size:53582233600,type:'part',fstype:'ext4',mountpoint:'/',uuid:'1111-2222',protected:true}
          ]},
          {name:'sdb',path:'/dev/sdb',size:107374182400,type:'disk',fstype:'',mountpoint:'',model:'Data Volume',protected:false,children:[
            {name:'sdb1',path:'/dev/sdb1',size:107373133824,type:'part',fstype:'ext4',mountpoint:'/data',uuid:'3333-4444',protected:false}
          ]}
        ],
        mounts:[
          {device:'/dev/sda1',fstype:'ext4',size:53582233600,used:12884901888,avail:40697331712,percent:'25%',mountpoint:'/',protected:true},
          {device:'/dev/sdb1',fstype:'ext4',size:107373133824,used:1073741824,avail:106299392000,percent:'1%',mountpoint:'/data',protected:false}
        ]
      };
      case machine+'/nginx':return {sites:[site],diagnostics:[],capabilities:{},php_sockets:[],ssl_renewal:{enabled:true,method:'systemd',unit:'certbot.timer',cron:false,detail:'certbot.timer'}};
      case machine+'/nginx/web/detail':return {source:'server {\n    listen 443 ssl;\n    server_name '+domain+';\n    location / { proxy_pass http://127.0.0.1:3000; }\n}',editable:false,domains:[domain],diagnostics:[],history:[]};
      case machine+'/nginx/web/ssl-status':return {served:{names:[domain],expires:'64 days'},timer:'active',cron:false,renewal:{enabled:true,method:'systemd',unit:'certbot.timer',cron:false,detail:'certbot.timer'}};
      case machine+'/nginx/web/logs':
      case machine+'/pm2':return [];
      case machine+'/jobs':return [{id:'sample',target:'web-demo',label:'Nginx',status:'succeeded',events:[{message:'nginx -t · OK'}]}];
    }
  }
  throw new Error(vpsEnglish?'Preview mode uses sample data. Switch to live data to run this action.':'Đang xem dữ liệu minh họa. Chuyển sang dữ liệu thật để thực hiện thao tác.');
}
