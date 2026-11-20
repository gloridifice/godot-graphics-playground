# 当前架构

## 入口与边界

- `project.godot` 主场景为 `scenes/fog_playground.tscn`，F5 启动 CSG 跳跃扰雾实验场；程序化森林保留为 `addons/heightfield_fog/demo.tscn`，可独立 F6 运行。使用 Godot 4.7.2 / Forward+；Windows 配置为 D3D12。
- 当前唯一雾效实现为 `addons/heightfield_fog/`，GDScript 管理节点、烘焙与初始化，Godot fog shader 与原生 FogVolume 负责显示。
- 旧 SWE GPU 求解器、玩家雾交互、全局高度场烘焙插件、旧实验场及其专属工具／测试／资源已移除。当前 addon 新增独立 GPU SWE：每盒推进厚度与水平动量，起跳注入动量。没有恢复旧全局求解器，也没有三维空气或四面体渲染；当前局部 SWE 支持资源风速驱动的背景输送与上风补雾／下风排雾；另可切换独立二维 Stable Fluids 后端，使用不可压空气速度输送初始厚度与显示材质坐标，不产生 SWE 式堆积。
- 保留通用 `scenes/player.tscn`、`scripts/player/`、`scripts/camera/`、`scripts/ui/`、网格地面 shader 和 Phantom Camera 插件，森林示例复用玩家与第三人称相机。第三方来源见 `THIRD_PARTY.md`。
- `addons/motion/` 提供 Mixamo 守卫模型、动画、原生 CharacterBody3D 控制器、Motion Matching、AnimationTree 状态机与 SpringArm3D 相机，已接入主场景；不依赖第三方控制器或 Phantom Camera。独立 F6 入口为 `addons/motion/demo.tscn`，用法、来源与资源使用限制见 [Motion 说明](../addons/motion/USAGE.md)和[来源](../addons/motion/SOURCE.md)。森林角色保持独立，不随本次替换。
- `addons/JehenoThirdPersonController/` 独立保留 Jeh3no 的控制器、相机、HUD、角色及测试地图；这是场景型资产，不是编辑器插件。主场景仅沿用其测试地图布局和地面贴图，不再实例化其角色。上游测试地图仍使用原控制器、启动捕获鼠标、Ctrl 切换；来源、许可及入口见 [导入说明](../addons/JehenoThirdPersonController/SOURCE.md)。

## 雾盒与烘焙

- `heightfield_fog_box.gd` 定义一个盒体对应一个局部高度场的 `HeightfieldFogBox` 节点。原点为底心，支持世界 Y 旋转、单位缩放。原生移动／旋转工具与 `box_gizmo.gd` 的宽高深手柄共同控制盒体，尺寸编辑支持撤销。
- `baker.gd` 收集 Source Root 下可见的静态 MeshInstance3D，排除蒙皮及 `heightfield_fog_ignore` 分组。使用 Godot 顺时针正面的向上三角形，在局部 X/Z 网格中心求交，仅接受底／顶高度区间内的结果，每格保留最高面。跨界斜面按采样位置裁剪，不夹平到盒顶。
- 无承载格无效，整盒无承载面则拒绝替换原纹理。地形纹理与烘焙签名仅驻留节点内存，场景不保存 Image／ImageTexture 数据或高度图资源引用。编辑器和运行时每次进入场景树都会清空缓存，延后两个处理帧自动烘焙，等待父场景生成几何；烘焙不标记场景为未保存。盒体变换、尺寸、分辨率或 Source Root 变化后旧结果不显示，需显式重烘焙或重新进入场景；场景内源几何编辑不自动扫描。
- 多个盒体可用不同高度区间分离上下楼层；每盒内部仍只保存一层。盒体不改变模型、玩家或相机碰撞。

## 初始化与显示

- `initialization.gd` 定义可保存为 `.tres` 的 `HeightfieldFogInitialization`。每盒默认独立资源，也可共享资产；共享编辑影响所有引用者，单独调整需 Make Unique。
- 参数包含基础高度、偏移、水平雾顶、初始厚度上限、浓度和确定性 fBm 的振幅／频率／层数／种子／采样偏移。初始化资产缓存一张盒体无关的 512² FastNoiseLite 无缝纹理，CPU 初态与 GPU 密度共享信号；种子／层数变化更新缓存，频率／偏移通过采样坐标生效。自然模式按世界坐标与风向拉伸采样，普通模式按局部坐标采样。
- 静态预览、SWE 和 Stable Fluids 都消费同一 `create_thickness()` 结果，shader 不再重建另一套程序化雾顶。先计算基准高度加噪波，Horizontal Top 开启时减承载高度，再裁零并应用 Max Thickness；高于雾顶的岩石不被雾毯覆盖。修改形状参数会重建每盒初态并重置 SWE，不重烘焙地形，不向共享资产写入盒体数据。旧 `layer_height` 兼容为基础高度，旧 Top Variation／Scale 迁移为噪波振幅／频率。
- `heightfield_fog.gdshader` 保留旧 2.5D 密度剖面和默认关闭的 Natural Mist。自然模式使用顶部 smoothstep 渐淡、竖向解析积分平均及基于同一噪波纹理的软覆盖率，形成贴地雾带和透明间隙。浓度、覆盖率、顶部软化与密度细节只更新显示，不重置物理状态。风速在静态模式只平移密度；启用 SWE 时同时输送厚度与扰动，上风边界按资源高度／噪波持续补雾、下风边界排出。静态密度偏移按节点 delta 积分，不依赖进程启动时间；开启 SWE 保留预览密度偏移为固定显示起点，初始化期间冻结，随后只叠加与边界共享的 GPU 输送偏移，防止零演化切换时换图案。开关重置物理场与输送偏移，但保留预览起点；显式重置和形状变化才将该起点清零。暂停同时冻结静态预览及模拟；风速实时生效、不重置，零风速停止风补入，仍允许向无承载处及盒外排出。两种模式都按局部侧边距离渐出厚度，不改变承载面。见 [薄雾生成合约](specs/heightfield-mist.md)。
- 原生 FogVolume 累积多个盒体，重叠增浓。盒顶限制烘焙承载高度，不是雾层硬顶盖；体积 Y 向留过滤余量。需要启用体积雾的 WorldEnvironment。
- `demo.gd` 在编辑器／运行时以固定种子生成 48×48 米起伏森林、土路、针叶树、倒木和大小岩石，不引入外部美术资源。`demo.tscn` 的 ClearingMist／DeepForestMist 覆盖空地与后方森林，共享 `presets/forest_mist.tres` 自然薄雾预设；两个盒底 Y=−2 m，基准雾顶为世界 Y=0.55 m，噪波振幅 0.35 m、频率 0.4，初始贴地厚度限制为 0.38 m，覆盖率控制为 0.5。运行时开启 SWE，从与编辑器一致的噪波薄层初始化；模拟可继续输送和堆积，不强制维持初始上限。旧预设留给分层测试；Source Root 限定为地形与岩石，排除树冠和倒木。游戏和测试场景启动时鼠标自由可见，F 锁定并隐藏后使用 WASD／鼠标／空格控制第三人称角色；Esc 释放，单击不捕获；所有雾盒进入场景时自动烘焙，森林无需单独调度。原双层解析几何测试独立保留在 `fixtures/stacked_floors.tscn`，不再依赖展示场景。

## CSG 雾实验场

- `scenes/fog_playground.tscn` 开启原生体积雾，背景密度为零；`FogFields` 下的 GroundMist、RampMist、SpawnPlatformMist 分别覆盖基础平台、斜坡与出生高台。三个盒体均使用贴承载面的薄层，并开启自然密度漂移。三个盒体默认开启 SWE，接收脚下起跳汇聚／落地扩散事件。运行时 F2 统一切换 SWE / Stable Fluids 并从同一初态重置，左下角显示后端；启动参数 `-- --stable-fluids` 可直接预览新版。Inspector 的 Simulation Method 支持逐盒选择，原 `swe_enabled`／`swe_editor_enabled`／`swe_paused` 字段为兼容保存场景而保留，对两后端均生效。
- `scripts/fog_playground.gd` 是场景专用 `@tool` 脚本：等待 CSG 更新后，通过 `get_meshes()` 将最终合并表面暴露为 `_FogCSGSurface`。派生节点不保存、不渲染、不投影、不创建碰撞，仅供现有 MeshInstance3D 烘焙器读取；不修改 addon 的通用烘焙合约。
- Source Root 限定 `Structures`，排除角色；编辑器和运行时进入场景时先构建 CSG 派生网格，再由各雾盒自动烘焙内存高度图，不再保存独立 `.res`。修改 CSG 后，选根节点点击 **Bake all playground fog**，刷新派生网格并重烘焙全部雾盒；烘焙结果不需保存，布局及参数编辑照常保存。

## 主场景角色与鼠标控制

- `addons/motion/motion_character.tscn` 使用脚底原点，`motion_character.gd` 直接继承原生 CharacterBody3D。WASD 相机相对移动；站立移动面向相机前方，A／D 使用左右横移、S 使用后退动画，不再转身播放向前走。按住 Shift 跑步、空格单次接地跳跃、按住 Ctrl 蹲伏／蹲行。蹲伏缩短独立胶囊但保持脚底不动；松开时先查询站立空间，低顶下保持蹲伏，离开后自动站起；蹲伏不能跳跃。真实 `move_and_slide()` 前后产生通用 `jumped`、`landed`、`ground_moved` 信号；出生接地不触发落地，落地需向下速度超过 1 m/s。
- 原生 `AnimationTree` 使用 `animations/locomotion.tres` 外层状态机：Grounded／Crouch 内由 Motion Matching 选择片段与时间，Jump／Fall 仍根据真实竖直速度和接地切换，0.12 s 过渡。`addons/motion/motion_matching/` 离线从统一守卫骨架动画采样 424 帧、22 维特征（双脚位置／速度、根水平速度、0.2／0.4／0.6 s 直线根偏移、接触）；运行时每 0.1 s 按真实相对平台速度、碰撞切线约束后的目标预测未来轨迹，以归一化加权距离检索兼容姿态标签的所有帧，并保留延续余量。Walk／Run 各自按库内根速度方向约束前后、横移两个检索通道，每通道用原生 A／B AnimationNodeAnimation → TimeSeek → TimeScale → Blend2 从匹配时间播放；方向 Blend2 按真实模型空间速度的 `|vx|/(|vx|+|vz|)` 持续混合前后／横移（45° 各占 50%），再由独立 Speed Blend2 按碰撞解算后相对平台的真实水平速度连续混合（默认 1.5／3／4.5 m/s 对应 Run 权重 0／0.5／1）；Shift 只改变物理目标，不直接切动画。零权重通道保持 sync 推进；另从接触上升沿估计循环相位原点，以四通道加权周期行程向量的长度计算共同步频，并通过 A/B 交叉混合对齐前后／横移及两步态相位，避免混合接触长期停留在半接触。接触曲线随最终骨骼一起混合；可变槽位节点逐角色深复制，检索库只读共享。原动画采样修改器位于 FootPlacement 之前，避免 IK 反馈；采样后新增可开关的骨骼局部姿态指数 decay，显示姿态持续追踪原生动画目标，默认半衰期 0.06 s，只影响 Grounded／Crouch，不修改物理移动或原生接触曲线。平滑历史逐角色保存于 IK 前，复位／传送／进入空中清空；首次求值和重新开启从当前目标初始化。Foot Placement 随后施加约束。骨骼动画不驱动角色位移；平台运输不算步态速度。详见 [Motion Matching](../addons/motion/motion_matching/USAGE.md)。
- `animations/mixamo.res` 存储统一到守卫骨架的动画与完整 RESET；重建工具 `addons/motion/tools/build_mixamo.gd` 一并生成动画库、播放图及检索库，不依赖 Blender。左右横移步行来自原 Mixamo 资源库；四向跑步使用本机已下载的 Run Forward、Jog Strafe Left／Right、Jog Backward。四向跑步和异骨架后退步行按骨名及全局静止姿态重定向、保留守卫骨长，支持不同 Mixamo 命名空间。一般按原根行程校准播放时长；四个原地跑步片段沿各自动作轴投影支撑区鞋底反向速度估计周期步幅，库内统一按 6 m/s 标定，Run／RunLeft／RunRight／RunBack 周期约为 0.468／0.296／0.245／0.258 s；这些方向仅为离线标定元数据，运行时依旧按库内速度／方向检索。控制器默认行走／跑步／蹲行 1.5／4.5／0.7 m/s，TimeScale 随实际速度和混合周期行程调整。Shift 下四向均使用真实跑步，不再以加速步行回退；高步频及斜后方全速跑的双脚锁定仍有已知不足，支撑测试不放宽。蹲行只有向前数据，仍向移动方向转身；没有八向、起停、转弯轨迹或脚步规划的完整数据覆盖。
- `addons/motion/climbing/` 实现守卫程序化悬挂：站姿角色在空中由左右肩附近正上方／前斜上方区域射线自动抓取，区域形状边界须贴合可见表面，实体碰撞独立。掌心锁区域局部变换，双臂可达性与悬垂姿态反推身体目标，由 CharacterBody3D 执行碰撞移动；Climb 静态完整姿态随后经抬肩／骨盆惯性摇摆、左右 TwoBoneIK3D 和末端掌心旋转求值。外层原生状态机新增 Climb，暂停地面匹配／decay 并清脚锁；WASD 沿单区域近似平面交替换手，无输入仍悬挂。吸附时 ESC 同时脱离和释放鼠标，逐角色标记禁止本次腾空对所有区域重抓，真实接地当 tick 清除（不依赖带速度阈值的 landed）；未吸附 ESC 和非主动支撑失效不设置标记。默认区域查询层 3，只读标定共享，锚点／摇摆／IK／禁用状态逐实例独立。demo 新增空闲地块的墙／顶面和最后两个 Tab 检查点，主场景亦实例化同一验证区。限制、求值和参数见[攀爬说明](../addons/motion/climbing/USAGE.md)及[合约](specs/motion-climbing.md)；不做平台翻越、跨区换手、复杂转角或踩墙脚 IK。
- `addons/motion/foot_placement/` 实现守卫骨架的 Foot Placement／Foot Lock：AnimationTree 先求值骨骼及离线估计的左右接触曲线，Skeleton3D 再按固定子节点顺序运行目标／骨盆修改器、两个独立 TwoBoneIK3D 和脚掌旋转修改器。二者使用 Manual 模式，在每个角色物理 tick 显式推进一次，不读取上一帧 IK 反馈。鞋底中心／脚跟／脚尖采样过滤自身和陡面；Swing／Approach／Contact／Stance／Release 分别由动画摆动、保持水平轨迹并临界阻尼修正高度、支撑局部 Hermite 减速、速度归零后捕获一次锁点、实际腿部局部旋转残差释放主导；默认 Contact 0.12 s，终点投影支撑平面。Release 默认约 0.083 s，停止该腿 TwoBoneIK，从末端修改器记录的实际大腿／小腿旋转和角速度开始，用五次残差曲线交回原生动画，避免腿接近伸直时位置 IK 把脚踝小位移放大为膝盖瞬变。脚掌朝向／骨盆参考仍沿世界空间 Hermite 交接，但释放期间不再强制脚踝位置；输出历史仅用于释放，不反馈检索或姿态追踪。Approach／Contact／Stance 的高度／朝向／水平锁定先合成为脚踝目标，原生 IK 不重复乘接触权重；静态支撑锁世界变换，移动支撑锁平台局部变换。骨盆限幅降低，接触／锁定时参考动画髋踝距离保留屈膝余量。支撑腿远离锁点时按相对平台速度预测，若降骨盆也无法保持余量则提前释放，不在同一接触段立即重锁。横移的膝盖导向连续保留侧向分量。角色碰撞体和扰雾坐标不变。跳跃、查询失效、支撑改变、超限转向／锁距和传送均有清锁或释放策略；只支持世界 Y 朝上和当前守卫标定，不提供台阶自动跨越或脚步规划。参数、边界和检查路线见 [脚部说明](../addons/motion/foot_placement/USAGE.md)。
- `addons/motion/demo.tscn` 保留低顶通道，并引用原生碰撞验证场：10／18／28 cm 方块、六级 12 cm 楼梯、三种半径球体、12° 纵坡／15° 横坡、平移并 yaw 的 AnimatableBody3D 平台。Tab／R 切换或复位检查点，F3／F4 切换调试和 IK，1／2 独立切换左右脚，面板显示阶段与权重、可调骨盆限幅，并提供姿态 decay 开关（F5）与半衰期滑条；这些交互仅属于 demo，不接入主场景输入。
- `addons/motion/ui/motion_matching_view.gd` 为主雾实验场和 demo 共用的只读运行时 Control，替代文字动画状态摘要：以数据库双脚模型空间 z（特征列 2／5）显示二维姿态点云，以 IK 前实际采样的 `pose_target`／`pose_current` 显示 P／p 与追踪短迹，并展示四通道最终贡献、decay 参数及数据流。它不是二维检索度量或新的 BlendSpace；空中动画显式标注 NATIVE、隐藏地面标记。内部 AnimationTree 与检索算法不变，UI 不截获鼠标；demo 左侧只保留调参与脚部诊断。点云在只读库变化时预建缓存 ArrayMesh，常态以全部帧背景／当前片段高亮两个批次提交，软边由顶点透明羽化提供，不逐帧逐点重新三角化；样式逐实例缓存，P／p、短迹和混合诊断仍逐帧更新。图形匹配测试检查完整图示额外 draw call 不超过 80，防止调试 UI 再次引入数百次绘制的回退。
- 接地行走由控制器在 `move_and_slide()` 前后采集真实脚底轨迹，经场景转发到各盒 `push_mist()`；按盒旋转转换世界轨迹，每批最多 16 个样本。独立 GPU 源项阶段只交换动量，产生前推、两侧分流及可调平面尾流，再由原 SWE 通量输送厚度；不生成／删除雾量，不依赖输入或模型朝向。静止、完全顶墙、空中不持续施力，0.8 m 高差外隔离；暂停期间的移动不缓存。体宽、耦合率与尾流强度在雾盒 Interaction / Movement 调整；森林未接入行走。物理依据及二维限制见[实验场指南](guides/playground.md#行走气流调研与二维近似)。
- `scripts/fog_playground.gd` 将起跳事件以 `-takeoff_pull`（默认 −0.8）、落地事件以 `landing_push`（默认 +1）传给各盒的 `disturb_mist()`。只注入水平动量，厚度汇聚、堆积与扩散由 SWE 通量产生；保留每盒高度隔离，不叠加视觉清空／扩散环。
- `addons/motion/motion_camera.gd` 使用原生 SpringArm3D 做碰撞避让和 Camera3D 环绕跟随。启动光标可见，物理 F 切换捕获／释放，Esc、窗口失焦或退出释放；单击、Ctrl 和重新获得焦点不捕获。释放时停止水平输入，但仍执行重力、动画、碰撞和真实落地事件，相机缩放仅在捕获时处理。缺失 Input Map 动作只在运行时补齐，不覆盖已有绑定。`MotionCharacter.set_external_input(axis, sprint, crouch, jump)` 提供逐角色脚本／回放输入：不依赖捕获或焦点，不写全局 Input，移动限长、跳跃沿触发并在物理 tick 消费；`clear_external_input()` 归还普通玩家控制。外部控制期间禁用相机输入事件，但沿用完整物理／动画流程。常规 Motion 和主雾实验场自动化通过测试驱动器使用此入口，窗口不可聚焦；真实捕获检查仅在显式 `--interactive-input` 下运行，森林旧输入测试未选择该标记时返回 2。

## 森林角色与物理

- `demo.tscn` 实例化项目 `scenes/player.tscn`；`demo.gd` 在土路入口按实际地形高度安置胶囊。玩家控制器沿相机水平基移动、使用正常重力与跳跃，释放鼠标或窗口失焦后停止输入。没有重新接入旧玩家扰雾求解器；demo 将 `jumped(feet_position)` 转发到各盒体的 `disturb_mist()`，只在起跳时向实际 SWE 状态注入径向动量。
- `scripts/camera/third_person_rig.gd` 与 Phantom Camera 提供第三人称跟随、限俯仰环绕及碰撞避让，跟随距离 4 m。统一控制器默认不捕获鼠标，只接受 Input Map 的 `capture_mouse`（物理 F）进入锁定隐藏状态；Esc、失焦或退出控制器释放，不因单击／重新获得焦点而捕获。相机碰撞层为环境 1，玩家为 2，避免被自身胶囊挡住。
- 程序化地面生成三角网格静态碰撞，岩石／树干／倒木主干生成凸碰撞；不生成树冠／细枝碰撞。地形四边增加防跌落边界；这些物理体与雾的承载高度图独立。
- 雾盒核心不依赖角色／相机；森林展示场景依赖项目玩家与 Phantom Camera，不是仅复制 addon 即具备的控制器。

## GPU SWE 与起跳

- `swe_solver.gd` 在全局 RenderingDevice 的渲染线程维护每盒独立双缓冲状态；`shaders/swe.glsl` 实现默认一阶的有限体积 Rusanov 型通量、静水重建、GPU CFL 归约与供给格排出量限制。每盒可选 `SWE Second Order`（默认关闭），用 MC 限制器重建自由面／速度及配套压力修正，干湿边／无效格／外边界退化为一阶；时间仍为显式一阶子步，二阶空间模式 CFL 收紧至 0.3。切换重置物理场、保留预览密度相位，不重烘焙；模板采样更多，主要减轻风输送的数值扩散。每盒 `SWE Gravity Threshold` 按离承载面的厚度控制产生压力的超出部分，默认 0 恢复原行为；同步调整压力修正、波速与重力质量扩散，使静止且不超阈值的薄雾不自行摊平。阈值实时生效、不重置状态，不阻止冲量与惯性输送，不是厚度硬下限。无承载格交界面与矩形盒边统一开放：风吹入有效格时生成，吹出时消失；无风／横风时仍允许压力或玩家动量向外排出，不镜像速度反弹。内部封闭孔洞同样适用，无效格本身不存雾，也不按无限高实体处理；不做外部空域连通性分类。动量以相对背景风的扰动存储，阻尼不衰减质量或背景风；开放通量通过边界增减总雾量。
- 初始场为高度图和初始化厚度；正常帧不回读 CPU。`swe_solver.gd` 为 `@tool`，节点通过独立且默认关闭的 `SWE Editor Enabled` 在编辑器复用同一求解器；开启／关闭均重建初态、清零动量和风偏移，关闭释放 GPU 状态并回到静态显示，动态状态不序列化。运行时只受 `SWE Enabled` 控制，`SWE Paused` 两端均适用。稳定的 R32F 输出经 Texture2DRD 直接绑定 FogVolume。自然模式保留软剖面和密度细节，但使用 SWE 厚度而非程序化雾顶。
- 60 Hz 固定 tick 内分子步，GPU 保证实际 CFL；过载有追赶上限与丢时诊断，极端 CFL 限制可能使物理时间落后。暂停保留状态，重置／基础参数变化／重烘焙重建状态，退出释放 GPU 资源。
- 起跳坐标转换到各盒局部，默认 2.5 m 范围注入 1.8 m/s 径向速度对应的动量，事件强度限定为 [−1, 1]，负值汇聚、正值扩散；省略强度时保留森林原有向外冲量。每次最多四事件，各施加一次。高差 1.5 m 外不施加，不直接删除厚度，也不按计时器恢复。旧视觉扩散环已移除。多个盒体独立响应及补雾／排雾，但不交换通量。
- `swe_metrics()` 返回异步 GPU timestamp 与独立 CPU 提交计时，`swe_snapshot()` 仅显式诊断回读。精确边界见 [局部高度雾 SWE 合约](specs/heightfield-swe.md)。

## GPU Stable Fluids（第一版）

- `stable_fluid_solver.gd` / `shaders/stable_fluid.glsl` 与 SWE 独立实现，复用地形、资源初态、FogVolume 和交互接口。MAC 面槽以四 float 分别保存相对背景风的空气速度和近地径向交互速度；每个 60 Hz tick 做中点回溯输送、一次性玩家源项、指数扰动阻尼、空气散度／Jacobi 压力求解与投影，再用风＋空气＋径向交互驱动材质回溯和厚度重建。`Stable Pressure Iterations` 默认 48，`Stable Drag` 默认 0.45 s⁻¹，均实时生效；SWE 的重力、阈值、阶数和阻尼不作用于本模式。
- 厚度由不可变的初始化 `h₀` 按反向材质坐标重建，不再插值上一 tick 厚度；单次初态采样仍有网格过滤，但匀速风不持续磨平高度噪波。材质坐标和来源权重逐 tick 回溯，复杂剪切／旋涡下仍有累积映射误差，不严格守恒；基础高度无重力自行摊平或水平汇聚堆积；没有独立高度增益时，均匀初态与匹配入口保持均匀。起跳／落地分别注入向内／向外的独立径向分量，近似竖向作用的水平投影，随后输送并受阻尼衰减，不再被空气压力投影立即消除；总速度不宣称二维无散。事件另在材质的空闲 `source.z` 通道注入高度乘数 `G∈[0,2]`（初态／中性为 `1`），输出 `h=h_base×G`。负强度挑高、正强度压低，默认目标分别为 `1.75`／`0.25`，按空间和高差权重向目标混合，不无限叠加。增益随同一流场输送，以默认 `0.8 s` 半衰期回到 `1`，独立于速度阻尼，不新增纹理或计算 pass、不生成原本为零的雾；不反馈压力或修改 `h₀`。速度耗散与增益恢复都不会复位坐标或原位置图案。行走主要保留投影后的绕流与尾流。地形高度用于承载显示与高差隔离，不形成 SWE 高地障碍。
- 盒边和无承载孔洞均为零外部压力的开放周界；材质回溯逐格检查第一个交界，背景风入口记录参考坐标和入口承载高度，后续从资源公式持续重建，不错误钳到盒内 `h₀`。每格以初态／入口权重及入口加权承载高度区分来源，剩余为空域；初态参考点越出承载域时剔除其残余权重并归一化剩余来源，防止伪零接缝。其余外部厚度为零。单轨迹最多检查 128 格面，预算耗尽记录 `trace_limited`，不跳过未检查孔洞。各盒仍不交换状态。
- GPU 保存不可变初始高度及每格 32 字节的材质／来源双缓冲，重建厚度直接绑定原 R32F Texture2DRD；另输出世界反向材质位移，Coverage／密度细节随局部气流卷动，不再双加全局风漂移。创建、计算和释放仍在全局 RenderingDevice 的渲染线程，无正常帧 CPU 场回读。开关／切换重置状态并把增益置为 `1`，暂停同时冻结增益恢复，预览起点生命周期与现有节点一致，不迁移动态状态。`swe_snapshot()` 在本模式返回独立的 scalar／height_gain／velocity 和投影诊断，不伪装成 SWE 动量；精确边界见 [Stable Fluids 合约](specs/heightfield-stable-fluid.md)。

## Split Radiance Cascades 间接光

- `addons/split_radiance_cascades/` 是独立 addon，不接入雾场或主场景。`SplitRadianceCascades` 作为 WorldEnvironment 子节点，在现有合成链后追加 Forward+ 的 POST_SKY 效果。可选 **Preview In Editor** 与运行时复用同一套快照和渲染代码；编辑器只覆盖当前编辑世界的 RenderingServer 合成链，不把临时 Compositor 写入场景。关闭预览、切换场景或移除节点时撤下效果、释放渲染资源；编辑器相机移动和调灯无需重建；修改静态几何、材质或源／代理路径后可点 **Rebuild GI Snapshot**。见[示例和接入说明](../addons/split_radiance_cascades/USAGE.md)。
- [`scenes/sponza_src_preview.tscn`](../scenes/sponza_src_preview.tscn) 默认在 3D 编辑视口预览 GI，也可按 F6 运行。使用 [Intel Sponza 2022 建筑和布幔](../assets/sponza/SOURCE.md) 的 430,092 个可见三角形及 2K JPG（质量 90）PBR 贴图；同源隐藏代理只用 51,372 个三角形做世界空间求交，没有上游烘焙光照。相机可切三个视点或用键盘飞行。Sponza 与 addon 小房间共用右上角计时表：引擎报告视口渲染 CPU／GPU 毫秒，SRC 以每实例、每次采样会话的 RD 时间戳异步报告八段 CPU 提交与 GPU 执行时间，接收面绘制（Receiver）和最终合成（Apply）分列；P 隐藏停采，普通节点默认不插标记。`tests/sponza_src_preview_test.gd` 在运行时检查 GI 开关画面差、计时单位及停采／恢复。addon 的 `tests/editor_preview_test.tscn` 在真实 3D 编辑视口验证预览开关、点光源实时调色与关闭、静态几何手动重建和保存隔离。
- 主线程为静态不透明三角网格与材质生成求交和接收面快照，静态输入修改后显式 `rebuild()`。默认使用有 65,536 面预算的软件 BVH；可选 `Prefer Hardware Trace` 在设备支持 RD 光追管线时，以网格局部空间的每个独立表面建一个 BLAS、实例变换建 TLAS，只替换 Trace 阶段（含次级和阴影射线）。建树与释放在渲染线程，不依赖内联 ray query；不支持时回退软件。同一代理下两后端共享采样、光照和级联算法；更换求交精度与更换后端是两件事。Directional／Omni 灯独立于快照：按节点进出树维护候选列表，检查有效灯光参数、世界变换和可见性。最多 8 盏；数据变化才更新 256 字节常驻缓冲并使主次探针历史失效，不重建 BVH、不重新上传接收面。GPU 从可见表面发射世界空间射线，按首次命中距离将光及此前区间的透射率写入四级稀疏方向探针；C3 接收超过 C2 边界的所有已知命中，真正未命中不发光。重叠 LOD 拆分样本权重；从远到近合并时，无局部样本或历史的方向保持无效，不被亮父级填充。稳定探针保留局部区间历史，次级命中写入独立粗缓存。
- `receiver_pass.gd` 按材质以索引绘制可见网格，在独立 sRGB 附件中按原场景深度匹配接收面，写入底色 × (1 − 金属度)，含 UV1 底色和金属度贴图。默认可见网格也用于追踪；指定 `Trace Proxy Root` 时，只有射线改用对齐的代理，接收面和灯仍来自 `Source Root`。Apply 读取线性底色乘以探针照明，不再逐像素遍历 BVH。世界空间射线命中读共享的常量材质表；若命中面有普通 UV1 贴图，重建时在 GPU 上分层采样同一 UV 的线性底色与金属度，平均 `底色 × (1 − 金属度)` 写入表中，不逐射线查贴图、不回读。无贴图代理与自发光项保持原值。要求单目、关闭 MSAA 3D；不依赖屏幕内存在光源或硬件光追。
- addon 内的 `tests/interval_bins_test.gd` 用受控射线验证未采样／遮挡／透射状态和重叠 LOD 的写入权重。`tests/render_test.gd` 读取无原生 GI 的最终画面，检查远处真实命中与未命中、近遮挡、稳定世界格、屏幕外次级反弹、接收面深度与底色贴图、点光源增删及父节点变换／可见性，以及卸载恢复。已在 Godot 4.7.2 / Forward+ / RTX 3070 的 D3D12、Vulkan 验证。`tools/profile_sponza_src.gd` 可测固定中庭，也可用 `software` / `hardware` / `visible` 对照固定拱廊的求交方式与几何精度，`no-proxy` 则直接测试原模型及其命中材质；720p、1080p 实测见 addon 的 [USAGE.md](../addons/split_radiance_cascades/USAGE.md)。

## 水体边界

水体实现、Shader、纹理、示例和测试由独立的 Godot 4.7.2 C++ 插件仓库 [Oceanus](../../oceanus/README.md) 维护。本项目不再内置水体，也不依赖 Oceanus；水体当前架构与合约见 [Oceanus 文档](../../oceanus/doco/architecture.md)。

## 验证与限制

- addon 的 `bake_test.gd` 覆盖真实场景保存／加载不保留高度图、加载与重复进入场景自动采样新几何，以及上下层分离、旋转盒、跨顶斜面及失效／失败烘焙；`initialization_test.gd` 覆盖初态高度／厚度上限、无效格／高岩石、噪波缓存失效、平移／旋转盒世界场一致性、资产保存加载及旧字段迁移。
- `natural_mist_test.gd` 用真实 Forward+ 画面检查低处有雾／高岩石露出、顶部软化、零风速稳定、旋转盒体的世界空间连续性和非零风速漂移，以及资源噪波频率确实影响静态与暂停的 SWE 初态、SWE 厚度纹理实际显示、旋转盒起跳坐标、外观编辑保留暂停状态和 GPU 资源重建、旋转盒运行时承载面缩小重烘焙后的周界通流；不把 headless 编译当作 shader 验证。
- `swe_test.gd` 在一阶／二阶空间模式下验证真实 GPU 的带实体高边的静水平衡、干湿推进、实体高地阻挡、非负和质量，以及向内汇聚／向外冲量、跨高度隔离、强冲量与模拟时钟；并用独立正弦平移解析解检查输送误差和有界性。行走另覆盖两阶数／两轴的前推、分流、尾流、厚度重分布、质量／时钟、停步衰减、高度隔离及 30／60 Hz 提交一致性。开放边界覆盖带外部无承载留白的平台在两阶数／四个风向下的均匀通流、排空／充填，以及封闭孔洞的零风排出和按风向补入。`natural_mist_test.gd` 另检查切换阶数重置真实扰动场。
- `addons/motion/tests/climbing_test.gd` 以无鼠标捕获的脚本输入、30／60／120 Hz 下验证地面不抓／空中自动抓、ESC 脱离与落地前禁用、无落地事件的轻接地重置、顶面横移／墙面上行、移动支撑局部锚点、非主动失效重抓和实体空间拒绝；读取最后一个修改器的最终掌心与朝向，对照独立盒体表面，不仅检查 IK 目标。当前 Godot 4.7.2 / Forward+ / D3D12 实测通过，并已检查顶面与墙面的实际画面。
- `addons/motion/tests/motion_character_test.gd` 从独立原生示例场景验证脚本输入行走／跑步、斜向限速、骨骼动画、Jump／Fall／接地、低顶蹲行与安全站起、双实例姿态隔离、逐角色指令隔离及跳跃沿触发；常规运行逐段检查鼠标始终可见，真实捕获／释放另需显式交互标记。
- `addons/motion/tests/contact_transition_test.gd` 通过真实物理、原生接触曲线及最后一个修改器的最终骨骼输出，验证 60／120 Hz 落地减速的位置／速度衔接、刚性支撑坐标系平移与旋转、8 cm 地面高差、Approach 水平保真、减速中跳跃清除；另在静态和移动／旋转支撑上检查 60／120／240 Hz 解锁入口／出口线与角速度的收敛和原生动画恢复，并通过逐角色脚本输入驱动完整控制器前走、后退及向左横移，检查同三种频率下解锁前后的实际屈膝余量（含起步），及稳定步态双腿完整 Release 期间逐物理 tick 的最终大腿／小腿角速度，覆盖直腿突弯而脚踝首尾仍平滑的回归；解锁中跳跃验证立即恢复原生腿姿、落地后正常重建释放。真实 Walk／Run、四象限方向混合和方向／速度同时混合继续检查双脚静止支撑，斜后方全速跑仍有上述已知不足。
- `addons/motion/tests/foot_placement_test.gd` 从真实 demo 的 `skeleton_updated` 回调读取最终骨骼，对照实际碰撞与解析台阶／坡面／球面验证脚部位置和朝向；覆盖前行／跑步／蹲行／可调步速及左右横移／后退的双脚支撑／摆动／释放、支撑期世界锁定、Approach 水平轨迹、楼梯真实下降、移动平台局部锚点、单腿开关、查询失效、自动传送清锁和实例隔离。不是仅检查 IK 目标节点或导出清单。
- `addons/motion/tests/speed_blend_test.gd` 无窗口推进真实 AnimationTree／Skeleton3D，验证纯步行／纯跑步端点、三个中间速度，以及四象限 20°／45°／70° 的步行／跑步方向混合与目标／实际速度、方向不一致时的结果；独立 AnimationPlayer 对照原生骨骼，确认中间速度和斜向姿态确实混合，而不是只更新 UI 数值。精确动画目标对照时关闭姿态追踪，另在原生修改器完成回调读取显示骨骼，检查 30／60／120 Hz 的半衰期和关闭／零半衰期／复位／空中旁路。
- `addons/motion/tests/motion_matching_test.gd` 通过真实前／左／右／后及 Shift 输入验证匹配动作、保持面向相机的移动、停步；用独立 AnimationPlayer 直接对照最终手脚姿态，检查匹配片段和任意采样时间确实被播放，而非只更新诊断字符串。墙前停步与自由横移角色并发验证可移动轨迹预测、逐实例槽位隔离。
- `tests/fog_playground_jump_test.gd` 从配置的主场景启动，验证真实 Motion 控制器跳跃／落地一次性事件、GPU 向内／向外动量和中心增厚／质量守恒，以及默认自由鼠标、F 双向切换、Esc／失焦释放、单击不捕获、释放期间仍可落地扰雾；另检查真实 WASD 行走的 GPU 顺行动量／质量守恒和暂停不回放行走。
- `tests/forest_walk_test.gd` 仅在显式 `--interactive-input` 下于有焦点的图形窗口检查真实场景落地、W 行走与贴坡、跳跃落地及 GPU 动量注入、默认自由鼠标、物理 F／Esc 切换、单击不捕获及地图边界阻挡。`tools/profile_forest_swe.gd` 可重复测量固定视角的模拟暂停／运行／起跳负载。
- `stable_fluid_test.gd` 验证真实 GPU 的静态初态、压力投影、尾流／高度隔离、有符号径向交互存续、独立仿射初态查值、远区保形／无定时复位、均匀基础厚度及材质输送、增益的 `[0,2]` 端点／半衰期／干格不生雾／随流输送／跨孔洞中性、旋转盒细尺度正弦长时间平移、四向开放入口、入口接缝／参考承载高度／反向风／入口噪波重建和跨孔洞回溯；从真实主场景验证 F2 双向切换同初态、暂停和重置。`tests/fog_playground_jump_test.gd -- --stable-fluids` 使用同一 Motion 控制器检查新版起跳升高／落地压低、径向速度、材质坐标输送和暂停不回放。当前通过 Godot 4.7.2 / Forward+ / D3D12 / RTX 3070；原 SWE 和自然雾 GPU 回归亦通过。没有其他驱动验证或新后端性能预算保证。
- 已有 GPU 路径使用 Forward+ / D3D12 冒烟运行；纯风输送及可选二阶空间重建已做解析平移与实际图像 GPU 检查，复杂场景的边界外观仍由用户验证。headless 检查不替代 GPU 验证。没有性能预算保证，也未承诺所有视角无走样；盒边渐出不等同于内部孔洞的距离场过滤。
- `doco/changes/` 与 `doco/tmp/` 的旧材料不代表当前实现，不作为启动或验证入口。

操作与命令见 [实验场指南](guides/playground.md) 和 [addon 说明](../addons/heightfield_fog/README.md)。
