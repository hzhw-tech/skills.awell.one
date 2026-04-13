---
name: balance-skill
description: 通过对话帮用户操作 Awell Balance 记账软件。用于记录收支流水、查询账单、管理账本和分类。当用户说"记一笔"、"今天花了"、"查一下账单"、"新建账本"等记账相关意图时使用。所有操作通过 curl 调用 https://balance.awell.one API 完成。
---

# Balance 记账助手

Base URL：`https://balance.awell.one`
认证方式：Cookie（`balance_session`），存储在 `/tmp/balance_cookies.txt`

---

## 一、认证

### 1.1 登录（会话开始时执行）

用户提供邮箱和密码后需要完成**两步登录流程**：

**步骤1：邮箱密码登录**

```bash
# 登录并保存临时 cookies
curl -s -D /tmp/balance_headers.txt -c /tmp/balance_cookies_temp.txt -X POST https://balance.awell.one/api/auth/sign-in/email \
  -H "Content-Type: application/json" \
  -d '{"email":"<EMAIL>","password":"<PASSWORD>"}'
```

**步骤2：获取最终的 balance_session cookie**

登录成功后，**必须使用临时 cookie 请求 callback 接口**以获取最终的 `balance_session`：

```bash
# 使用临时 cookie 请求 callback，获取最终的 balance_session
curl -s -D /tmp/balance_headers_final.txt -b /tmp/balance_cookies_temp.txt -c /tmp/balance_cookies.txt \
  "https://balance.awell.one/auth/callback?locale=zh&returnTo=%2Fdashboard"
```

**登录成功后的处理：**

1. 第一步登录会在响应头的 `set-cookie` 中返回临时认证 cookie
2. 第二步 callback 会返回最终的 `balance_session` cookie，保存到 `/tmp/balance_cookies.txt`
3. **后续所有请求必须使用最终的 cookie 文件 `-b /tmp/balance_cookies.txt`**

```bash
# 后续请求示例：
curl -s -b /tmp/balance_cookies.txt https://balance.awell.one/api/books
```

**完整登录脚本示例：**

```bash
# 步骤1：邮箱密码登录
curl -s -D /tmp/balance_headers.txt -c /tmp/balance_cookies_temp.txt -X POST https://balance.awell.one/api/auth/sign-in/email \
  -H "Content-Type: application/json" \
  -d '{"email":"<EMAIL>","password":"<PASSWORD>"}'

# 步骤2：获取最终 balance_session
curl -s -D /tmp/balance_headers_final.txt -b /tmp/balance_cookies_temp.txt -c /tmp/balance_cookies.txt \
  "https://balance.awell.one/auth/callback?locale=zh&returnTo=%2Fdashboard"

# 验证登录是否成功
curl -s -b /tmp/balance_cookies.txt https://balance.awell.one/api/auth/get-session
```

### 1.2 检查会话

在以下情况需要检查会话有效性：

```bash
curl -s -b /tmp/balance_cookies.txt https://balance.awell.one/api/auth/get-session
```

- 返回 `{"session":null}` → 会话已失效
- 返回 `401 Unauthorized` → 会话已失效
- 返回有效的用户信息 → 会话正常

### 1.3 自动重新登录机制

**触发条件：**
- **任何接口返回 `401 Unauthorized` 状态码**
- 用户主动说"重新登录"、"刷新登录"
- `get-session` 接口返回 `{"session":null}`

**处理流程：**

1. 检测到 401 后，立即提示用户"登录已失效，正在重新登录..."
2. 使用上次保存的邮箱密码重新执行 1.1 登录
3. 登录成功后，重试刚才失败的操作
4. 如果重新登录也失败，提示用户检查账号密码

**示例处理代码逻辑：**

```bash
# 调用 API
response=$(curl -s -w "\n%{http_code}" -b /tmp/balance_cookies.txt https://balance.awell.one/api/books)
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

# 检查状态码
if [ "$http_code" = "401" ]; then
  echo "检测到 401，重新登录中..."
  # 步骤1：重新登录
  curl -s -D /tmp/balance_headers.txt -c /tmp/balance_cookies_temp.txt -X POST https://balance.awell.one/api/auth/sign-in/email \
    -H "Content-Type: application/json" \
    -d '{"email":"<EMAIL>","password":"<PASSWORD>"}'
  # 步骤2：获取最终 balance_session
  curl -s -D /tmp/balance_headers_final.txt -b /tmp/balance_cookies_temp.txt -c /tmp/balance_cookies.txt \
    "https://balance.awell.one/auth/callback?locale=zh&returnTo=%2Fdashboard"
  # 重试原请求
  curl -s -b /tmp/balance_cookies.txt https://balance.awell.one/api/books
fi
```

### 1.4 Cookie 持久化注意事项

- Cookie 文件 `/tmp/balance_cookies.txt` 在系统重启后会消失，需重新登录
- 每次会话开始时，如果 cookie 文件不存在或已过期，需要先执行登录
- 建议在每次 skill 启动时，先检查会话有效性（调用 `get-session`）

---

## 二、账本（Books）

### 2.1 列出账本（绝大多数操作前先调用，拿到 bookId）

```bash
curl -s -b /tmp/balance_cookies.txt https://balance.awell.one/api/books
```

返回 `{ "books": [{ "id", "name", "isDefault", "isShared", "budgetAmount" }] }`

**规则：** 若用户未指定账本，优先使用 `isDefault: true` 的那个。

### 2.2 获取单个账本

```bash
curl -s -b /tmp/balance_cookies.txt https://balance.awell.one/api/books/<bookId>
```

### 2.3 创建账本

```bash
curl -s -b /tmp/balance_cookies.txt -X POST https://balance.awell.one/api/books \
  -H "Content-Type: application/json" \
  -d '{"name":"<名称>","isShared":false,"budgetAmount":"<月预算，可选>"}'
```

### 2.4 更新账本

```bash
curl -s -b /tmp/balance_cookies.txt -X PATCH https://balance.awell.one/api/books/<bookId> \
  -H "Content-Type: application/json" \
  -d '{"name":"<新名称>","isDefault":true,"budgetAmount":"<新预算>"}'
```

### 2.5 删除账本

```bash
curl -s -b /tmp/balance_cookies.txt -X DELETE https://balance.awell.one/api/books/<bookId>
```

---

## 三、分类（Categories）

每条流水必须关联分类。分类有 `type: income | expense`。

### 3.1 列出分类

```bash
# 全部分类
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/categories?bookId=<bookId>"

# 仅支出分类
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/categories?bookId=<bookId>&type=expense"

# 仅收入分类
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/categories?bookId=<bookId>&type=income"
```

返回 `{ "categories": [{ "id", "type", "name", "icon", "color", "isArchived" }] }`

**规则：** 用户描述消费/收入时，根据语义匹配分类名称；若无完全匹配，选最近似的，并告知用户。

### 3.2 创建分类

```bash
curl -s -b /tmp/balance_cookies.txt -X POST https://balance.awell.one/api/categories \
  -H "Content-Type: application/json" \
  -d '{"bookId":"<bookId>","type":"expense","name":"<名称>","icon":"<emoji>","color":"<hex色值>"}'
```

`icon` 用 emoji，`color` 用 `#rrggbb` 格式，颜色根据分类语义自动选取。

### 3.3 更新分类

```bash
curl -s -b /tmp/balance_cookies.txt -X PATCH https://balance.awell.one/api/categories/<categoryId> \
  -H "Content-Type: application/json" \
  -d '{"name":"<新名称>","isArchived":false}'
```

---

## 四、流水（Entries）——核心功能

`occurredAt` 格式：ISO 8601，如 `2026-04-13T14:30:00.000Z`。未指定时间时，使用当前时刻。

### 4.1 记一笔（最常用）

**触发词：** "记一笔"、"花了"、"收入"、"买了"、"付了"、"赚了"等

流程：

1. 调用 2.1 获取账本，确认 bookId
2. 调用 3.1 获取对应类型分类，匹配 categoryId
3. 创建流水

```bash
curl -s -b /tmp/balance_cookies.txt -X POST https://balance.awell.one/api/entries \
  -H "Content-Type: application/json" \
  -d '{
    "bookId": "<bookId>",
    "type": "expense",
    "amount": "<金额字符串，如 38.50>",
    "categoryId": "<categoryId>",
    "occurredAt": "<ISO8601时间>",
    "remark": "<备注，可选>"
  }'
```

**确认逻辑：** 记录前向用户复述"账本：xxx，类型：支出，金额：38.5，分类：餐饮，时间：今天 14:30，备注：午饭"，用户确认后再发请求。

### 4.2 查询流水

**触发词：** "查一下"、"看看账单"、"本月花了多少"等

```bash
# 查询某账本全部流水
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/entries?bookId=<bookId>"

# 按时间区间（本月）
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/entries?bookId=<bookId>&dateFrom=2026-04-01&dateTo=2026-04-30"

# 按类型
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/entries?bookId=<bookId>&type=expense"

# 按分类
curl -s -b /tmp/balance_cookies.txt "https://balance.awell.one/api/entries?bookId=<bookId>&categoryId=<categoryId>"
```

查询结果以表格形式展示：日期 | 类型 | 分类 | 金额 | 备注，并汇总收入/支出合计。

### 4.3 修改流水

先通过 4.2 找到对应 entryId：

```bash
curl -s -b /tmp/balance_cookies.txt -X PATCH https://balance.awell.one/api/entries/<entryId> \
  -H "Content-Type: application/json" \
  -d '{"amount":"<新金额>","remark":"<新备注>"}'
```

### 4.4 删除流水

```bash
curl -s -b /tmp/balance_cookies.txt -X DELETE https://balance.awell.one/api/entries/<entryId>
```

删除前向用户确认。

---

## 五、常见对话场景

| 用户说             | 操作路径                              |
| ------------------ | ------------------------------------- |
| 今天午饭花了 35    | 2.1 → 3.1(expense) → 4.1              |
| 查本月账单         | 2.1 → 4.2(dateFrom/dateTo)            |
| 工资到账 8000      | 2.1 → 3.1(income) → 4.1               |
| 新建一个旅行账本   | 2.3                                   |
| 帮我加个"健身"分类 | 2.1 → 3.2                             |
| 刚才那笔记错了     | 4.2(找entryId) → 4.3                  |
| 删掉昨天那笔外卖   | 4.2(找entryId) → 4.4                  |
| 本月餐饮共花多少   | 2.1 → 3.1(找categoryId) → 4.2(按分类) |

---

## 六、注意事项

### 6.1 数据格式
- `amount` 字段为**字符串**，传 `"38.50"` 而非数字 `38.50`
- `occurredAt` 使用 ISO 8601 格式：`2026-04-14T10:30:00.000Z`

### 6.2 默认行为
- 未指定账本时默认用 `isDefault: true` 的账本
- 分类匹配失败时告知用户并提供最近似选项，不要自行创建新分类（除非用户明确要求）

### 6.3 错误处理与重试
- **所有 API 调用都必须检查返回的 HTTP 状态码**
- **遇到 401 立即触发重新登录，然后重试原操作**
- 遇到其他错误码（400/403/404/500 等）应向用户报告具体错误信息
- 登录失败时不要无限重试，最多重试 1 次，失败后提示用户检查账号密码

### 6.4 用户体验
- 操作成功后以自然语言回复，不要直接把 JSON 响应堆给用户
- 记录流水前向用户复述确认信息
- 删除操作前必须确认

### 6.5 会话管理
- Cookie 文件 `/tmp/balance_cookies.txt` 在系统重启后会消失，需重新登录
- 建议在 skill 启动时先调用 `get-session` 检查会话有效性
- 如果用户长时间未操作（超过 1 小时），主动提醒可能需要重新登录
