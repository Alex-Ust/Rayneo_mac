# Живое зеркало очков + редактирование мышкой

Дата: 2026-06-01

## Цель

Добавить в окно приложения (на Маке) живое зеркало рендера очков — те же 3
квада с тем же содержимым, что видно в очках. Поверх него мышкой:

- кликом выбрать экран (та же синяя рамка, что в очках),
- перетащить экран мышкой → меняется азимут/высота,
- колесом над экраном → дистанция,
- перетащить приложение из полоски на экран → пин этого приложения в слот.

## Камера превью

Стабильная по умолчанию (смотрит прямо, экраны не болтаются — удобно тянуть).
Галочка **Follow head** включает слежение за головой (точное зеркало очков).
Стабильная камера = единичный кватернион; follow = живой `imu->snapshot().view`.

## Компоненты

### 1. `RNSScene` — переиспользуемый рендер (`src/app/scene.mm`)
Выделить из `drawInMTKView:` метод
`- (void)renderInto:(MTKView*)view orientation:(simd_quatf)q`.
- `drawInMTKView:` (для очков) зовёт его с `imu->snapshot().view`.
- Превью зовёт его со своим кватернионом камеры.
Пайплайн, геометрия, сэмплер, `quadTextures` и `captureSources` — единый
источник истины в одном `RNSScene`. Превью НИЧЕГО не дублирует, только рисует.

C++-glue в `scene.h`:
`void sceneRenderInto(Scene s, void* mtkView, const float quat[4]);`

### 2. `RNSPreviewView` — превью + ввод (`src/app/preview_view.{h,mm}`)
`MTKView` (сам себе `MTKViewDelegate` и `NSDraggingDestination`). Хранит:
`Scene` (для `sceneRenderInto`), `ImuService*`, `id<MTLDevice>`,
`id<RNSControlActions>` (для пина), `BOOL followHead`.
- `drawInMTKView:` → строит кватернион камеры (identity либо imu view) →
  `sceneRenderInto`.
- `mouseDown:` → `pickSlot` под курсором → `config().selectedSlot`.
- `mouseDragged:` → `cursorToAzEl` → пишет `azimuthDeg/elevationDeg`
  выбранного экрана (дистанция не меняется).
- `scrollWheel:` → меняет `distanceM` выбранного экрана.
- drag-destination (тип `NSPasteboardTypeString` = имя приложения):
  `performDragOperation` → `pickSlot` под точкой дропа →
  `[actions pinAppNamed:slotName toIndex:slot]`.

### 3. Пикинг и направление курсора (`src/app/pick.h`, header-only)
Чистая геометрия, без состояния сцены (читает `config().screens`):
- `dir_eye = normalize(ndcX*tanX, ndcY*tanY, -1)`, `tanY=tan(fovY/2)`,
  `tanX=tanY*aspect`; `fovY` из `fovDiagonalDeg` + aspect (как в сцене).
- `dir_world = rotate(conjugate(cam), dir_eye)`. Камера в начале координат
  (голова в origin, квады вокруг origin).
- `int pickSlot(ndcX, ndcY, aspect, fovDiagDeg, cam)` — луч из origin вдоль
  `dir_world`, пересечь с каждым видимым квадом (плоскость + проверка
  локальных границ по осям right*sx / up*sy из `quadModelMatrix`), вернуть
  ближайший слот или -1.
- `void cursorToAzEl(..., float& azDeg, float& elDeg)` — из `dir_world`:
  `el = asin(dy)`, `az = atan2(dx, -dz)` (обратно к `quadModelMatrix`).

### 4. Встраивание в панель (`src/app/control_panel.{h,mm}`)
`makeControlPanel` получает дополнительно `Scene`, `ImuService*`, `void* device`.
Сверху стека панели:
- `RNSPreviewView` (фикс. высота ~220pt),
- чекбокс **Follow head** (→ `preview.followHead`),
- горизонтальная полоска запущенных приложений (иконка+имя), каждая —
  drag-source (`RNSAppDragItem : NSView`, `mouseDragged:` →
  `beginDraggingSessionWithItems`, на pasteboard кладёт имя приложения).
Ниже — существующие контролы без изменений.

### 5. Проводка (`src/app/app.mm`)
Передать `self.scene`, `self.imu`, `self.mtlDevice` в `makeControlPanel`.

## Синхронизация
Всё пишет в единый `config()`-синглтон. Реальный рендер очков читает его
живьём каждый кадр → мгновенное отражение. Слайдеры/хоткеи/превью трогают те
же поля → всегда согласованы. Save/Reset уже работают на `config()`.

## Потоки
Обе `MTKView` рисуют независимо. `MTLCommandQueue` потокобезопасна для
создания командных буферов; capture-текстуры читаются только на чтение. Если
проявится контеншн — дать превью отдельную `MTLCommandQueue` (запас).

## Вне scope (пока)
Ресайз за уголок на превью (это делают слайдеры Size), вид сверху/карта.
```
