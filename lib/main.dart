import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:math' as math;

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Schematic Manager (MCP)',
      theme: ThemeData.dark(), // 适配为暗黑主题更美观
      home: SchematicManager(),
    );
  }
}

// 专门渲染原理图图形连线的绘图器
class GraphicLinePainter extends CustomPainter {
  final List<dynamic> lines;
  GraphicLinePainter(this.lines);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.lightBlueAccent.withOpacity(0.5) // 原理图导线颜色
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    for (var line in lines) {
      if (line is List && line.length >= 4) {
        // 画布中心设定为 5000
        double x1 = (line[0] as num).toDouble() / 2 + 5000;
        double y1 = (line[1] as num).toDouble() / 2 + 5000;
        double x2 = (line[2] as num).toDouble() / 2 + 5000;
        double y2 = (line[3] as num).toDouble() / 2 + 5000;
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// 渲染逻辑网络的绘图器 (如果有的话)
class NetPainter extends CustomPainter {
  final Map<String, dynamic> parts;
  final Map<String, dynamic> nets;

  NetPainter(this.parts, this.nets);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeWidth = 2.0..style = PaintingStyle.stroke;
    final colors =[Colors.greenAccent, Colors.orangeAccent, Colors.purpleAccent, Colors.pinkAccent, Colors.yellow];
    int colorIdx = 0;

    for (var entry in nets.entries) {
      String netName = entry.key.toString();
      var pins = entry.value;
      if (pins is! List || pins.isEmpty) continue;

      paint.color = (netName.toUpperCase() == 'GND') ? Colors.grey.withOpacity(0.5) 
          : (netName.toUpperCase() == 'VCC' || netName.toUpperCase() == '+5V') ? Colors.redAccent.withOpacity(0.8) 
          : colors[(colorIdx++) % colors.length].withOpacity(0.7);

      List<Offset> points =[];
      for (var pinObj in pins) {
        List<String> pinParts = pinObj.toString().split('.'); 
        if (pinParts.isNotEmpty && parts.containsKey(pinParts[0])) {
          var info = parts[pinParts[0]];
          double rawX = info['x'] is num ? (info['x'] as num).toDouble() : double.tryParse(info['x']?.toString() ?? '0') ?? 0.0;
          double rawY = info['y'] is num ? (info['y'] as num).toDouble() : double.tryParse(info['y']?.toString() ?? '0') ?? 0.0;
          // 没有+25/+30补偿了，这样直接对齐画布原点
          points.add(Offset(rawX / 2 + 5000, rawY / 2 + 5000));
        }
      }

      if (points.length > 1) {
        for (int i = 0; i < points.length - 1; i++) {
          canvas.drawLine(points[i], points[i + 1], paint);
        }
      } else if (points.length == 1) {
        canvas.drawCircle(points.first, 6.0, paint..style = PaintingStyle.fill);
      }
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true; 
}

class SchematicManager extends StatefulWidget {
  @override
  _SchematicManagerState createState() => _SchematicManagerState();
}

class _SchematicManagerState extends State<SchematicManager> {
  WebSocketChannel? _sharedChannel;
  Map<String, dynamic> _ascData = {"parts": <String, dynamic>{}, "nets": <String, dynamic>{}, "lines": <dynamic>[]};
  String _filePath = "";
  String _originalFilePath = ""; // 【新增】记录原始拖入或选中的文件路径
  int _rpcIdCounter = 0;
  String _apiEndpoint = 'https://api.deepseek.com/v1/chat/completions';
  String _apiKey = '';
  String _model = 'deepseek-chat';
  bool _isWebSocketConnected = false;
  
  // AI对话相关变量
  List<Map<String, dynamic>> _chatMessages = [];
  bool _isAiChatting = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initializeWebSocket();
  }

  // 从外部配置文件读取DS密钥
  Future<String> _loadDsKeyFromConfig() async {
    try {
      // 使用标准的配置目录路径
      String configPath = '/home/dpiner/.config/asc_mcp_cheker/config.json';
      File configFile = File(configPath);
      
      if (await configFile.exists()) {
        String content = await configFile.readAsString();
        Map<String, dynamic> config = jsonDecode(content);
        return config['ds_key'] ?? '';
      }
    } catch (e) {
      print('读取配置文件时出错: $e');
    }
    return '';
  }

  // 加载API设置
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    String savedApiKey = prefs.getString('apiKey') ?? '';
    
    // 如果SharedPreferences中没有保存密钥，则尝试从外部配置文件加载
    if (savedApiKey.isEmpty) {
      savedApiKey = await _loadDsKeyFromConfig();
    }
    
    setState(() {
      _apiEndpoint = prefs.getString('apiEndpoint') ?? 'https://api.deepseek.com/v1/chat/completions';
      _apiKey = savedApiKey;
      _model = prefs.getString('model') ?? 'deepseek-chat';
    });
  }

  // 保存API设置
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiEndpoint', _apiEndpoint);
    await prefs.setString('apiKey', _apiKey);
    await prefs.setString('model', _model);
  }

  void _initializeWebSocket() {
    try {
      _sharedChannel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:8080')); 
      _sharedChannel!.stream.listen((data) {
        try {
          var raw = jsonDecode(data as String);
          if (raw['result'] != null && raw['result']['content'] != null) {
            var content = raw['result']['content'];
            if (content is Map && content.containsKey('parts')) {
              setState(() {
                _ascData = Map<String, dynamic>.from(content);
                if (_ascData.containsKey('actual_path')) _filePath = _ascData['actual_path'].toString();
                _isWebSocketConnected = true;
              });
            }
          }
        } catch (e) { 
          print("Error: $e"); 
        }
      }, onError: (error) {
        print("WebSocket Error: $error");
        setState(() {
          _isWebSocketConnected = false;
        });
      });
    } catch (e) { 
      print("WS Error: $e"); 
      setState(() {
        _isWebSocketConnected = false;
      });
    }
  }

  void _refreshData() {
    if (_sharedChannel == null || _filePath.isEmpty) return;
    _sharedChannel!.sink.add(jsonEncode({"jsonrpc": "2.0", "id": ++_rpcIdCounter, "method": "tools/call", "params": {"name": "get_full_data", "arguments": {"file_path": _filePath}}}));
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'zip']);
    if (result != null && result.files.first.path != null) {
      setState(() {
        _originalFilePath = result.files.first.path!; // 【新增】
        _filePath = result.files.first.path!;
      });
      _refreshData();
    }
  }

  Widget _buildCanvas() {
    Map<String, dynamic> parts = _ascData['parts'] != null ? Map<String, dynamic>.from(_ascData['parts']) : {};
    Map<String, dynamic> nets = _ascData['nets'] != null ? Map<String, dynamic>.from(_ascData['nets']) : {};
    List<dynamic> graphicLines = _ascData['lines'] != null ? List<dynamic>.from(_ascData['lines']) :[];

    return InteractiveViewer(
      constrained: false,
      boundaryMargin: EdgeInsets.all(5000), // 为大坐标系保留巨大拖动边界
      minScale: 0.01,
      maxScale: 5.0,
      child: Container(
        width: 10000,  // 画布扩大至一万像素
        height: 10000, 
        decoration: BoxDecoration(color: Color(0xFF1E1E1E), border: Border.all(color: Colors.blueGrey.withOpacity(0.3))),
        child: Stack(
          children:[
            // 绘制网格线
            ...List.generate(100, (i) => Positioned(left: i * 100.0, top: 0, bottom: 0, child: Container(width: 1, color: Colors.white10))),
            ...List.generate(100, (i) => Positioned(top: i * 100.0, left: 0, right: 0, child: Container(height: 1, color: Colors.white10))),
            
            // 绘制图形布线
            Positioned.fill(child: CustomPaint(painter: GraphicLinePainter(graphicLines))),
            // 绘制逻辑网络
            Positioned.fill(child: CustomPaint(painter: NetPainter(parts, nets))),

            // 绘制器件节点
            ...parts.entries.map((entry) {
              String id = entry.key;
              Map info = entry.value;
              double rawX = info['x'] is num ? (info['x'] as num).toDouble() : double.tryParse(info['x']?.toString() ?? '0') ?? 0.0;
              double rawY = info['y'] is num ? (info['y'] as num).toDouble() : double.tryParse(info['y']?.toString() ?? '0') ?? 0.0;
              
              // 关键修正：器件的容器本身有宽高，减去一半，让卡片中心完美对齐绘图点
              double displayX = rawX / 2 + 5000 - 25;
              double displayY = rawY / 2 + 5000 - 30;

              return Positioned(
                left: displayX,
                top: displayY,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      // 拖拽时，本地反算新坐标
                      _ascData['parts'][id]['x'] = rawX + details.delta.dx * 2;
                      _ascData['parts'][id]['y'] = rawY + details.delta.dy * 2;
                    });
                  },
                  onSecondaryTapDown: (details) {
                    _showEditComponentDialog(id, info); // 弹出编辑对话框
                  },
                  child: Container(
                    width: 50, // 固定容器尺寸以精确对齐连线
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.2),
                      border: Border.all(color: Colors.cyanAccent, width: 1.5),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children:[
                        Text(id, style: TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                        Icon(Icons.memory, color: Colors.cyanAccent, size: 16),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  // 弹窗逻辑
  void _showEditComponentDialog(String id, Map info) {
    final nameController = TextEditingController(text: id);
    final deviceController = TextEditingController(text: info['Device']);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("编辑器件: $id"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: InputDecoration(labelText: "位号 (Designator)")),
            TextField(controller: deviceController, decoration: InputDecoration(labelText: "型号 (Device)")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text("取消")),
          ElevatedButton(
            onPressed: () {
              // 发送更新请求给 Rust
              _sendUpdateToBackend(id, nameController.text, deviceController.text);
              Navigator.pop(context);
            },
            child: Text("保存修改"),
          ),
        ],
      ),
    );
  }

  void _sendUpdateToBackend(String oldId, String newId, String newDevice) {
    if (_sharedChannel == null || _filePath.isEmpty) return;
    _sharedChannel!.sink.add(jsonEncode({
      "jsonrpc": "2.0", 
      "id": ++_rpcIdCounter, 
      "method": "tools/call", 
      "params": {
        "name": "update_component",
        "arguments": {
          "file_path": _filePath,
          "old_id": oldId,
          "new_id": newId,
          "new_device": newDevice
        }
      }
    }));
    // 刷新数据以显示更新
    Timer(Duration(milliseconds: 500), _refreshData);
  }

  // 辅助方法：发送坐标更新给 Rust
  void _sendPositionUpdateToBackend(String id, double x, double y) {
    if (_sharedChannel == null || _filePath.isEmpty) return;
    _sharedChannel!.sink.add(jsonEncode({
      "jsonrpc": "2.0",
      "id": ++_rpcIdCounter,
      "method": "tools/call",
      "params": {
        "name": "update_position",
        "arguments": {
          "file_path": _filePath,
          "component_id": id,
          "new_x": x,
          "new_y": y
        }
      }
    }));
  }

  // 爆炸布局算法
  void _explodeLayout() {
    if (_ascData['parts'] == null || _ascData['parts'].isEmpty) return;

    Map<String, dynamic> parts = Map<String, dynamic>.from(_ascData['parts']);
    List<String> keys = parts.keys.toList();
    int count = keys.length;

    // 爆炸半径：值越大，散得越开 (Schematic 原始坐标单位)
    double radius = 800.0 + (count * 50); 
    // 中心点 (通常设为原点 0,0)
    double centerX = 0;
    double centerY = 0;

    for (int i = 0; i < count; i++) {
      String id = keys[i];
      // 计算每个器件的角度
      double angle = (2 * 3.1415926 * i) / count;
      
      double newX = centerX + radius * math.cos(angle);
      double newY = centerY + radius * math.sin(angle);

      // 1. 更新本地状态实现瞬时动画效果
      setState(() {
        _ascData['parts'][id]['x'] = newX;
        _ascData['parts'][id]['y'] = newY;
      });

      // 2. 同步到后端持久化
      _sendPositionUpdateToBackend(id, newX, newY);
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已完成一键爆炸布局"), duration: Duration(seconds: 1)),
    );
  }

  // 【新增】保存文件方法
  void _saveFile() {
    if (_sharedChannel == null || _originalFilePath.isEmpty || _filePath.isEmpty) return;
    
    _sharedChannel!.sink.add(jsonEncode({
      "jsonrpc": "2.0", 
      "id": ++_rpcIdCounter, 
      "method": "tools/call", 
      "params": {
        "name": "save_file",
        "arguments": {
          "original_path": _originalFilePath, // 原始 zip/txt 路径
          "modified_txt_path": _filePath      // 被修改的临时 txt 路径
        }
      }
    }));
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("已发送保存请求: $_originalFilePath")),
    );
  }

  // 【新增】调用后端的清空工具
  void _sendClearNetsToBackend() {
    if (_sharedChannel == null || _filePath.isEmpty) return;
    _sharedChannel!.sink.add(jsonEncode({
      "jsonrpc": "2.0",
      "id": ++_rpcIdCounter,
      "method": "tools/call",
      "params": {
        "name": "clear_all_nets", // 对应 Rust 中的新工具
        "arguments": {"file_path": _filePath}
      }
    }));
  }

  void _sendAddNetPinToBackend(String netName, String pin) {
    if (_sharedChannel == null || _filePath.isEmpty) return;
    _sharedChannel!.sink.add(jsonEncode({
      "jsonrpc": "2.0",
      "id": ++_rpcIdCounter,
      "method": "tools/call",
      "params": {
        "name": "add_net_pin",
        "arguments": {
          "file_path": _filePath,
          "net_name": netName,
          "pin": pin
        }
      }
    }));
  }

  // 读取提示词文件
  Future<String> _loadPrompt() async {
    try {
      return await DefaultAssetBundle.of(context).loadString('lib/prompt.txt');
    } catch (e) {
      print('读取提示词文件时出错: $e');
    }
    // 默认提示词
    return "你是一个专业的电子工程师和原理图分析专家。你的任务是帮助用户分析和理解电子原理图。";
  }

  // 【新增】解析 AI 返回的 Markdown 中的 JSON
  Map<String, dynamic>? _extractAiJson(String response) {
    try {
      final regex = RegExp(r'```json\n(.*?)\n```', dotAll: true);
      final match = regex.firstMatch(response);
      if (match != null && match.groupCount >= 1) {
        return jsonDecode(match.group(1)!);
      }
    } catch (e) {
      print("JSON 解析失败: $e");
    }
    return null;
  }

  // 【新增】校验单个操作是否有效
  Map<String, dynamic> _validateOperation(Map<String, dynamic> op) {
    String action = op['action'] ?? '';
    String targetId = op['target_id'] ?? '';
    bool isValid = false;
    String errorMsg = '';

    if (action == 'clear_all_nets') {
      return {"valid": true, "error": "", "op": op}; // 全局操作永远有效
    }
    
    if (action == 'add_net_pin') {
      // 校验：targetId 必须包含点号(.)，且位号部分必须存在
      String netName = op['net_name'] ?? '';   // 对应网络名，如 "VCC_3V3"
      if (targetId.contains('.') && netName.isNotEmpty) {
        String designator = targetId.split('.')[0];
        if (_ascData['parts'] != null && _ascData['parts'].containsKey(designator)) {
          return {"valid": true, "error": "", "op": op};
        } else {
          return {"valid": false, "error": "器件 $designator 不存在", "op": op};
        }
      }
      return {"valid": false, "error": "无效的引脚或网络名", "op": op};
    }
    
    if (action == 'update_part' || action == 'move_part') {
      if (_ascData['parts'] != null && _ascData['parts'].containsKey(targetId)) {
        isValid = true;
      } else {
        errorMsg = '器件 $targetId 不存在';
      }
    } else {
      errorMsg = '不支持的操作类型: $action';
    }

    return {
      "valid": isValid,
      "error": errorMsg,
      "op": op
    };
  }

  // 【新增】执行 AI 的指令集
  void _executeAiOperations(List<dynamic> validatedOps) {
    for (var vOp in validatedOps) {
      if (vOp['valid'] == true) {
        var op = vOp['op'];
        String action = op['action'];

        if (action == 'add_net_pin') {
          _sendAddNetPinToBackend(op['net_name'], op['target_id']);
          
          // 本地立即更新 UI
          setState(() {
            _ascData['nets'] ??= {};
            _ascData['nets'].putIfAbsent(op['net_name'], () => []);
            if (!(_ascData['nets'][op['net_name']] as List).contains(op['target_id'])) {
              (_ascData['nets'][op['net_name']] as List).add(op['target_id']);
            }
          });
        }
        else if (action == 'clear_all_nets') {
          // 1. 发送给后端持久化删除
          _sendClearNetsToBackend();
          
          // 2. 立即更新本地 UI 状态（让用户看到连线消失）
          setState(() {
            _ascData['nets'] = {}; 
          });
        } 
        else if (action == 'update_part' && op['new_attributes'] != null) {
          String targetId = op['target_id'];
          String newDevice = op['new_attributes']['Device'] ?? '';
          if (newDevice.isNotEmpty) {
            // 调用现有的后端更新方法
            _sendUpdateToBackend(targetId, targetId, newDevice);
          }
        } else if (action == 'move_part') {
          String targetId = op['target_id'];
          // 这里可以调用你后端的 handle_update_position
          // _sendPositionUpdateToBackend(targetId, op['new_x'], op['new_y']);
        }
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已应用 AI 的有效修改")));
  }

  // 发送消息到AI
  Future<String> _sendToAI(String message) async {
    if (_apiKey.isEmpty) {
      return "错误：未配置API密钥";
    }

    String systemPrompt = await _loadPrompt();

    final url = Uri.parse(_apiEndpoint);
    final requestBody = {
      "model": _model,
      "messages": [
        {"role": "system", "content": systemPrompt},
        {"role": "user", "content": message}
      ],
      "stream": false
    };

    try {
      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $_apiKey",
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['choices'][0]['message']['content'].toString();
      } else {
        return "错误: ${response.statusCode} - ${response.body}";
      }
    } catch (e) {
      return "请求错误: $e";
    }
  }

  // 显示AI对话框
  void _showAiChatDialog() {
    TextEditingController messageController = TextEditingController();

    // 发送消息的函数
    void sendMessage() async {
      String message = messageController.text.trim();
      if (message.isEmpty) return;

      setState(() {
        _chatMessages.add({"role": "user", "content": message});
        _isAiChatting = true;
      });
      messageController.clear();

      // 【新增】将当前原理图的状态压缩后作为上下文发给 AI
      String contextData = jsonEncode({
        "parts": _ascData['parts'],
        // 如果 nets 太大，可以限制只发送相关的，这里简写发送全部
        "nets": _ascData['nets'] 
      });
      
      // 组装带有 System Prompt 设定的终极提示词
      String finalPrompt = "当前原理图数据:\n$contextData\n\n用户指令:\n$message";

      String aiResponse = await _sendToAI(finalPrompt);

      // 【新增】解析与校验
      var aiJson = _extractAiJson(aiResponse);
      List<dynamic> validatedOps =[];
      String displayText = aiResponse;

      if (aiJson != null) {
        displayText = aiJson['analysis'] ?? "已生成修改方案。";
        List<dynamic> ops = aiJson['operations'] ?? [];
        validatedOps = ops.map((op) => _validateOperation(op)).toList();
      }

      setState(() {
        _chatMessages.add({
          "role": "assistant", 
          "content": displayText,
          "validated_ops": validatedOps
        });
        _isAiChatting = true;
      });
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text("AI 对话"),
            content: Container(
              width: 600,
              height: 500,
              child: Column(
                children: [
                  Expanded(
                    child: _chatMessages.isEmpty
                        ? Center(
                            child: Text(
                              "开始与AI对话，询问关于原理图的问题",
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _chatMessages.length,
                            itemBuilder: (context, index) {
                              var msg = _chatMessages[index];
                              bool isUser = msg["role"] == "user";
                              
                              // 【新增】如果是 AI 消息且包含解析好的操作
                              List<dynamic> validatedOps = msg["validated_ops"] ?? [];
                              String textContent = msg["content"] ?? "";

                              return Container(
                                margin: EdgeInsets.symmetric(vertical: 8),
                                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  padding: EdgeInsets.all(12),
                                  constraints: BoxConstraints(maxWidth: 500),
                                  decoration: BoxDecoration(
                                    color: isUser ? Colors.blue[800] : Colors.grey[850],
                                    borderRadius: BorderRadius.circular(8),
                                    border: isUser ? null : Border.all(color: Colors.white24),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children:[
                                      Text(textContent, style: TextStyle(color: Colors.white)),
                                      
                                      // 【新增】渲染 AI 的操作面板
                                      if (!isUser && validatedOps.isNotEmpty) ...[
                                        Divider(color: Colors.white54, height: 20),
                                        Text("AI 建议的操作:", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
                                        SizedBox(height: 8),
                                        ...validatedOps.map((vOp) {
                                          bool isValid = vOp['valid'];
                                          var op = vOp['op'];
                                          return Container(
                                            margin: EdgeInsets.only(bottom: 4),
                                            padding: EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: isValid ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                                              border: Border.all(color: isValid ? Colors.green : Colors.red),
                                              borderRadius: BorderRadius.circular(4)
                                            ),
                                            child: Row(
                                              children:[
                                                Icon(isValid ? Icons.check_circle : Icons.error, 
                                                     color: isValid ? Colors.green : Colors.red, size: 16),
                                                SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    "${op['action']} -> ${op['target_id']}",
                                                    style: TextStyle(color: Colors.white70, fontSize: 13),
                                                  ),
                                                ),
                                                if (!isValid) 
                                                  Text(vOp['error'], style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                                              ],
                                            ),
                                          );
                                        }).toList(),
                                        
                                        // 【新增】一键应用按钮
                                        if (validatedOps.any((vOp) => vOp['valid'] == true))
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: ElevatedButton.icon(
                                              icon: Icon(Icons.play_arrow, size: 16),
                                              label: Text("执行有效操作"),
                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700]),
                                              onPressed: () => _executeAiOperations(validatedOps),
                                            ),
                                          )
                                      ]
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Container(
                    margin: EdgeInsets.only(top: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: messageController,
                            decoration: InputDecoration(
                              hintText: "输入消息...",
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (value) => sendMessage(),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.send),
                          onPressed: () => sendMessage(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _chatMessages.clear();
                  });
                  Navigator.of(context).pop();
                },
                child: Text("清空对话"),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text("关闭"),
              ),
            ],
          );
        },
      ),
    );
  }

  // 显示API设置对话框
  void _showApiSettingsDialog() {
    final endpointController = TextEditingController(text: _apiEndpoint);
    final keyController = TextEditingController(text: _apiKey);
    final modelController = TextEditingController(text: _model);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("API 设置"),
        content: Container(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: endpointController,
                decoration: InputDecoration(labelText: "API 端点"),
              ),
              TextField(
                controller: keyController,
                decoration: InputDecoration(labelText: "API 密钥"),
                obscureText: true,
              ),
              TextField(
                controller: modelController,
                decoration: InputDecoration(labelText: "模型名称"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("取消"),
          ),
          ElevatedButton(
            onPressed: () async {
              setState(() {
                _apiEndpoint = endpointController.text;
                _apiKey = keyController.text;
                _model = modelController.text;
              });
              await _saveSettings();
              Navigator.pop(context);
            },
            child: Text("保存"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("AI Schematic TXT Manager"),
        actions: [
          // WebSocket连接状态指示器
          Container(
            padding: EdgeInsets.only(right: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "后端服务",
                  style: TextStyle(fontSize: 12),
                ),
                SizedBox(width: 5),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isWebSocketConnected ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.chat),
            onPressed: _showAiChatDialog,
            tooltip: "AI 对话",
          ),
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _showApiSettingsDialog,
          ),
          IconButton(
            icon: Icon(Icons.auto_awesome_motion), // 爆炸/散开图标
            onPressed: _explodeLayout,
            tooltip: "一键爆炸布局",
          ),
          IconButton(
            icon: Icon(Icons.save),
            onPressed: _saveFile, // 【新增】绑定保存方法
            tooltip: "保存更改",
          ),
          IconButton(icon: Icon(Icons.folder_open), onPressed: _pickFile),
        ],
      ),
      body: Row(
        children:[
          Container(
            width: 200,
            child: ListView(
              children: (_ascData['parts'] != null ? Map<String, dynamic>.from(_ascData['parts']) : {}).keys.map((k) {
                final partInfo = _ascData['parts'][k] != null ? Map<String, dynamic>.from(_ascData['parts'][k]) : {};
                return ListTile(
                  leading: Icon(Icons.extension, color: Colors.blue),
                  title: Text(k.toString(), style: TextStyle(fontSize: 14)),
                  subtitle: Text(partInfo['Device']?.toString() ?? "", style: TextStyle(fontSize: 12)),
                );
              }).toList(),
            ),
          ),
          Expanded(
            child: DragTarget<String>(
              onAccept: (data) { 
                setState(() {
                  _originalFilePath = data; // 【新增】
                  _filePath = data; 
                }); 
                _refreshData(); 
              },
              onWillAccept: (_) => true,
              builder: (context, candidateData, rejectedData) {
                return _filePath.isEmpty
                  ? Center(child: Text("请拖入 .txt 或 .zip 文件", style: TextStyle(color: Colors.white70, fontSize: 18)))
                  : _buildCanvas();
              },
            ),
          )
        ],
      ),
    );
  }
}
