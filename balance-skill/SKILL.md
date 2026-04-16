---
name: balance-skill
description: 通过对话帮用户操作 「宜记」 记账软件。用于记录收支流水、查询账单、管理账本和分类。当用户说“记一笔”、“今天花了”、“查一下账单”、“新建账本”等记账相关意图时使用。支持多个 agent 共享同一 skill，并为多个用户分别保存登录凭证；执行任何记账或查询前先解析要使用的身份 account-id，再通过脚本读取对应 cookie 调用 https://balance.awell.one API。
---

# Balance 记账助手

Base URL: `https://balance.awell.one`

所有认证都通过 [`scripts/auth.sh`](./scripts/auth.sh) 完成。不要再把 cookie 或登录态写到 `/tmp`。

本 skill 的本地凭证目录固定为：

```text
balance-skill/.credentials/
  current_account.txt
  <account-id>/
    credentials.json
    profile.json
    cookies.txt
```

`account-id` 是给 agent 使用的身份标识，例如 `personal`、`work`、`alice-home`。它不一定等于邮箱。

## 一、身份解析

在任何 API 操作前，先确定“这笔操作要使用哪个身份”：

1. 如果用户明确指定了身份、账号、邮箱或别名，优先用那个身份。
2. 如果用户没指定，但当前只有一个已登录身份，可以直接使用它。
3. 如果用户没指定，且存在多个身份：
   - 如果语境能明确映射到某个身份，就直接使用那个身份。
   - 如果仍然不明确，先问用户“这笔要记到哪个身份？”
4. 如果当前没有可用身份，先引导用户执行登录。

默认身份只用于“没有歧义”的情况。不要在多身份并存时擅自替用户选人。

## 二、认证

### 2.1 首次登录或新增身份

使用固定脚本登录，并把完整登录信息保存到 skill 目录内：

```bash
./balance-skill/scripts/auth.sh login <account-id> <email> <password>
```

示例：

```bash
./balance-skill/scripts/auth.sh login personal alice@example.com 'mypassword'
./balance-skill/scripts/auth.sh login work alice@company.com 'mypassword'
```

脚本会：

1. 调用邮箱密码登录接口。
2. 调用 callback 接口拿到最终 `balance_session`。
3. 把 `credentials.json`、`profile.json`、`cookies.txt` 保存在 `balance-skill/.credentials/<account-id>/` 下。
4. 把该身份写入 `current_account.txt`，作为当前激活身份。

### 2.2 查看和切换身份

```bash
./balance-skill/scripts/auth.sh current
./balance-skill/scripts/auth.sh current --json
./balance-skill/scripts/auth.sh list
./balance-skill/scripts/auth.sh list --json
./balance-skill/scripts/auth.sh switch <account-id>
```

优先使用 `--json` 版本给 agent 读。

### 2.3 获取 cookie 路径

所有后续 API 都应先通过脚本拿 cookie 路径，而不是手写路径：

```bash
COOKIE_FILE="$(./balance-skill/scripts/auth.sh cookie-path <account-id>)"
```

如果省略 `account-id`，脚本会使用当前激活身份：

```bash
COOKIE_FILE="$(./balance-skill/scripts/auth.sh cookie-path)"
```

### 2.4 检查会话

优先用脚本检查：

```bash
./balance-skill/scripts/auth.sh session <account-id>
```

或直接调接口：

```bash
COOKIE_FILE="$(./balance-skill/scripts/auth.sh cookie-path <account-id>)"
curl -s -b "$COOKIE_FILE" https://balance.awell.one/api/auth/get-session
```

判定规则：

- 返回 `{"session":null}`: 会话已失效
- 返回 `401 Unauthorized`: 会话已失效
- 返回有效用户信息: 会话正常

### 2.5 自动重新登录

触发条件：

- 任意业务接口返回 `401`
- `get-session` 返回 `{"session":null}`
- 用户主动要求“重新登录”“刷新登录”

处理流程：

1. 告知用户当前身份的登录态已失效。
2. 执行：

```bash
./balance-skill/scripts/auth.sh relogin <account-id>
```

3. 脚本会读取 `balance-skill/.credentials/<account-id>/credentials.json` 中保存的邮箱和密码，重新换取新的 cookie。
4. 重新执行刚才失败的 API 请求。
5. 如果 `relogin` 失败，再让用户重新提供账号密码。

注意：`credentials.json` 中存有明文密码，只能保存在本机 skill 目录中，且不得输出给用户或写入日志。

## 三、API 调用约定

每次调用前先准备：

```bash
ACCOUNT_ID="<account-id>"
COOKIE_FILE="$(./balance-skill/scripts/auth.sh cookie-path "$ACCOUNT_ID")"
```

所有请求都必须检查 HTTP 状态码。推荐模式：

```bash
response=$(curl -s -w "\n%{http_code}" -b "$COOKIE_FILE" https://balance.awell.one/api/books)
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$http_code" = "401" ]; then
  ./balance-skill/scripts/auth.sh relogin "$ACCOUNT_ID" >/dev/null
  COOKIE_FILE="$(./balance-skill/scripts/auth.sh cookie-path "$ACCOUNT_ID")"
  response=$(curl -s -w "\n%{http_code}" -b "$COOKIE_FILE" https://balance.awell.one/api/books)
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
fi
```

## 四、账本（Books）

绝大多数操作前先列出账本，拿到 `bookId`：

```bash
COOKIE_FILE="$(./balance-skill/scripts/auth.sh cookie-path <account-id>)"
curl -s -b "$COOKIE_FILE" https://balance.awell.one/api/books
```

返回：

```json
{ "books": [{ "id": "...", "name": "...", "isDefault": true, "isShared": false, "budgetAmount": "..." }] }
```

规则：若用户未指定账本，优先使用 `isDefault: true` 的账本。

### 4.1 获取单个账本

```bash
curl -s -b "$COOKIE_FILE" https://balance.awell.one/api/books/<bookId>
```

### 4.2 创建账本

```bash
curl -s -b "$COOKIE_FILE" -X POST https://balance.awell.one/api/books \
  -H "Content-Type: application/json" \
  -d '{"name":"<名称>","isShared":false,"budgetAmount":"<月预算，可选>"}'
```

### 4.3 更新账本

```bash
curl -s -b "$COOKIE_FILE" -X PATCH https://balance.awell.one/api/books/<bookId> \
  -H "Content-Type: application/json" \
  -d '{"name":"<新名称>","isDefault":true,"budgetAmount":"<新预算>"}'
```

### 4.4 删除账本

```bash
curl -s -b "$COOKIE_FILE" -X DELETE https://balance.awell.one/api/books/<bookId>
```

## 五、分类（Categories）

每条流水必须关联分类。分类有 `type: income | expense`。

### 5.1 列出分类

```bash
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/categories?bookId=<bookId>"
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/categories?bookId=<bookId>&type=expense"
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/categories?bookId=<bookId>&type=income"
```

返回：

```json
{ "categories": [{ "id": "...", "type": "expense", "name": "餐饮", "icon": "🍜", "color": "#ef4444", "isArchived": false }] }
```

规则：根据用户语义匹配分类；若无完全匹配，选最近似并告知用户。

### 5.2 创建分类

```bash
curl -s -b "$COOKIE_FILE" -X POST https://balance.awell.one/api/categories \
  -H "Content-Type: application/json" \
  -d '{"bookId":"<bookId>","type":"expense","name":"<名称>","icon":"<emoji>","color":"<hex色值>"}'
```

### 5.3 更新分类

```bash
curl -s -b "$COOKIE_FILE" -X PATCH https://balance.awell.one/api/categories/<categoryId> \
  -H "Content-Type: application/json" \
  -d '{"name":"<新名称>","isArchived":false}'
```

## 六、流水（Entries）

`occurredAt` 使用 ISO 8601，例如 `2026-04-13T14:30:00.000Z`。未指定时间时，使用当前时刻。

### 6.1 记一笔

触发词：“记一笔”“花了”“收入”“买了”“付了”“赚了”等。

流程：

1. 解析身份 `account-id`
2. 列出账本，确定 `bookId`
3. 列出对应类型分类，确定 `categoryId`
4. 如果金额、类型、时间、身份、账本这些关键信息足够，就直接创建流水
5. 只有在关键信息缺失或身份不明确时才追问用户

```bash
curl -s -b "$COOKIE_FILE" -X POST https://balance.awell.one/api/entries \
  -H "Content-Type: application/json" \
  -d '{
    "bookId":"<bookId>",
    "type":"expense",
    "amount":"<金额字符串，如 38.50>",
    "categoryId":"<categoryId>",
    "occurredAt":"<ISO8601时间>",
    "remark":"<备注，可选>"
  }'
```

默认不要在记账前询问“是否确认”。应先尽量从用户原话中补全信息并直接记账。

记账完成后，必须用自然语言回执，至少包含：

- 使用的身份 `account-id`
- 账本名称
- 收支类型
- 金额
- 分类
- 时间
- 备注（如果有）
- 结果状态（已记账 / 失败）

回执示例：
“已为 `personal` 记账：账本‘日常’，支出 38.5 元，分类‘餐饮’，时间今天 14:30，备注‘午饭’。”

只有在以下情况才允许先问用户再记：

- 无法判断要用哪个身份
- 无法判断是收入还是支出
- 缺少金额
- 用户表达明显含糊，存在高概率记错的风险

### 6.2 查询流水

```bash
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/entries?bookId=<bookId>"
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/entries?bookId=<bookId>&dateFrom=2026-04-01&dateTo=2026-04-30"
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/entries?bookId=<bookId>&type=expense"
curl -s -b "$COOKIE_FILE" "https://balance.awell.one/api/entries?bookId=<bookId>&categoryId=<categoryId>"
```

输出时用自然语言或表格总结：日期 | 类型 | 分类 | 金额 | 备注，并汇总收入/支出合计。

### 6.3 修改流水

先查询定位 `entryId`，再修改：

```bash
curl -s -b "$COOKIE_FILE" -X PATCH https://balance.awell.one/api/entries/<entryId> \
  -H "Content-Type: application/json" \
  -d '{"amount":"<新金额>","remark":"<新备注>"}'
```

### 6.4 删除流水

```bash
curl -s -b "$COOKIE_FILE" -X DELETE https://balance.awell.one/api/entries/<entryId>
```

删除前必须确认，并明确要删除的是哪个身份下的数据。

## 七、常见对话场景

| 用户说 | 操作路径 |
| --- | --- |
| 今天午饭花了 35 | 身份解析 → 账本 → 分类(expense) → 创建流水 |
| 帮我记到 work 账号，晚饭 56 | 身份解析(work) → 账本 → 分类(expense) → 创建流水 |
| 查 personal 这个月账单 | 身份解析(personal) → 账本 → 查询流水 |
| 工资到账 8000 | 身份解析 → 账本 → 分类(income) → 创建流水 |
| 新建一个旅行账本 | 身份解析 → 创建账本 |
| 帮我加个健身分类 | 身份解析 → 账本 → 创建分类 |
| 刚才那笔记错了 | 身份解析 → 查流水找 entryId → 修改 |
| 删掉昨天那笔外卖 | 身份解析 → 查流水找 entryId → 删除 |

## 八、注意事项

### 8.1 数据格式

- `amount` 必须是字符串，如 `"38.50"`
- `occurredAt` 使用 ISO 8601

### 8.2 默认行为

- 未指定账本时，默认用 `isDefault: true` 的账本
- 分类匹配失败时，提供最近似选项，不要擅自新建分类
- 多身份并存时，身份不明确就先问，不要默认乱记

### 8.3 错误处理

- 所有 API 调用都必须检查 HTTP 状态码
- 遇到 `401` 立即 `relogin`，然后只重试一次
- 遇到 `400/403/404/500` 时，提炼错误信息再告诉用户
- 登录失败时最多重试 1 次

### 8.4 用户体验

- 操作成功后用自然语言回复，不直接堆原始 JSON
- 记录流水时默认直接执行，不做事前确认
- 记账完成后反馈：身份、账本、类型、金额、分类、时间、备注、结果
- 只有关键信息缺失或存在明显歧义时才追问
- 删除操作前必须确认

### 8.5 凭证安全

- 凭证只保存在 `balance-skill/.credentials/` 下，不使用 `/tmp`
- `credentials.json` 含明文密码，只允许本地脚本读取
- 不要把密码、cookie 内容或完整 session 回显给用户
