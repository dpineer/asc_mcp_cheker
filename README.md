# ASC MCP Checker

ASC MCP Checker 是一个基于 Flutter 的原理图管理工具，通过 Model Context Protocol (MCP) 与后端服务通信，实现原理图的可视化、编辑和 AI 辅助分析功能。

## 功能特性

- **原理图可视化**：支持 .txt 和 .zip 格式的原理图文件，提供交互式可视化界面
- **器件编辑**：支持器件位号和型号的修改
- **AI 辅助分析**：集成 DeepSeek API，提供原理图分析和自动修改建议
- **一键爆炸布局**：使用环形散开算法，将重叠的器件均匀分布
- **网络管理**：支持添加网络连接和清空所有网络连接
- **实时同步**：前端操作实时同步到后端进行持久化

## 系统架构

- **前端**：Flutter 应用，提供图形界面和用户交互
- **通信协议**：WebSocket + JSON-RPC，实现前后端通信
- **后端**：Rust 服务，处理原理图数据和业务逻辑

## 安装与运行

### 前提条件

- Flutter SDK
- Rust 工具链
- 后端服务 (asc_mcp_server)

### 安装步骤

1. 克隆项目：
   ```bash
   git clone <repository-url>
   cd asc_mcp_cheker
   ```

2. 安装 Flutter 依赖：
   ```bash
   flutter pub get
   ```

3. 确保后端服务正在运行：
   ```bash
   # 启动后端服务 (假设在端口 8080)
   asc_mcp_server
   ```

4. 运行应用：
   ```bash
   flutter run
   ```

## 配置

### API 密钥配置

应用支持两种方式配置 DeepSeek API 密钥：

1. **外部配置文件**：在 `~/.config/asc_mcp_cheker/config.json` 中配置：
   ```json
   {
     "ds_key": "your-deepseek-api-key"
   }
   ```

2. **应用内设置**：通过设置界面直接配置 API 端点、密钥和模型名称

### 默认模型

默认使用 `deepseek-chat` 模型，可在设置中更改。

## 使用说明

### 基本操作

1. **加载文件**：拖拽 .txt 或 .zip 文件到应用窗口，或点击文件夹图标选择文件
2. **查看原理图**：使用鼠标滚轮缩放，拖拽移动视图
3. **编辑器件**：右键点击器件弹出编辑对话框
4. **保存更改**：点击保存图标将修改保存到原始文件

### AI 功能

1. **AI 对话**：点击聊天图标打开 AI 对话框
2. **发送指令**：输入关于原理图的指令或问题
3. **查看建议**：AI 会分析原理图并提供修改建议
4. **执行操作**：验证 AI 建议后可执行有效操作

### 一键爆炸布局

当原理图中器件重叠时，可点击爆炸图标按钮，使用环形散开算法将器件均匀分布。

### 网络管理

- **添加网络**：AI 可建议添加网络连接，格式为 `add_net_pin`
- **清空网络**：AI 可建议清空所有网络连接，格式为 `clear_all_nets`

## 支持的操作类型

- `update_part`：修改器件属性（如型号）
- `move_part`：移动器件位置
- `add_net_pin`：将引脚加入网络
- `clear_all_nets`：清除所有网络连接

## 安全性

- API 密钥存储在用户配置目录中，不会上传到版本控制系统
- .gitignore 文件已配置，忽略所有配置和密钥相关文件

## 开发

### 项目结构

```
lib/
├── main.dart      # 主应用文件
└── prompt.txt     # AI 提示词模板
```

### 主要组件

- `_SchematicManagerState`：核心状态管理
- `GraphicLinePainter`：图形连线绘制器
- `NetPainter`：网络连接绘制器
- `WebSocketChannel`：前后端通信通道

## 故障排除

1. **WebSocket 连接失败**：检查后端服务是否在运行且端口正确
2. **API 调用失败**：检查 API 密钥是否正确配置
3. **文件加载失败**：确认文件格式为 .txt 或 .zip 且格式正确

## 许可证

CC BY NC SA