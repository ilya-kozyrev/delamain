package main

// The -demo mode: no hub home, a scripted team of agents building an HRM system instead, for showing hub-viz on a stage.
// It publishes /state and /events like the live mode, so the page and the screen saver need nothing of their own. The
// script loops; its lines are grouped by stage so the camera does not jump across the city on every line.

import (
	"strings"
	"time"
)

type demoAgent struct{ role, engine, model, title string }

type demoStep struct {
	stage, from string   // from: a worker's role, "hub" or "owner"
	to          []string // a role of the same stage, "hub", "owner", or "hub:<stage>"
	text        string
	join        []demoAgent // workers that take off before the line
	done        []string    // workers that go idle after it
	ask         int         // change of the stage's open owner questions after it
	pause       float64     // extra seconds before the line
}

type demoStage struct{ name, repo, goal string }

var demoStages = []demoStage{
	{"hrm-core", "hrm-platform", "Ядро HRM: сотрудники, оргструктура, права доступа"},
	{"payroll", "hrm-payroll", "Расчёт зарплаты, премий и НДФЛ"},
	{"portal", "hrm-portal", "Портал сотрудника: отпуска, документы, заявки"},
	{"analytics", "hrm-analytics", "Витрины и дашборд для руководства"},
}

const demoGap = 5.0 // seconds between lines: readable, and the camera moves on before the scene goes stale

var demoScript = []demoStep{
	// kickoff
	{stage: "hrm-core", from: "owner", to: []string{"hub"},
		text: "Собираем HRM за две недели: оргструктура, отпуска, зарплата, портал"},
	{stage: "hrm-core", from: "hub", to: []string{"architect"}, join: []demoAgent{{"architect", "claude", "claude-fable-5-1", "Модель данных HRM"}},
		text: "@architect спроектируй модель: сотрудник, должность, подразделение"},
	{stage: "hrm-core", from: "architect", to: []string{"hub"}, done: []string{"architect"},
		text: "Схема готова: 14 таблиц, история должностей, решение в ADR-001"},
	{stage: "hrm-core", from: "hub", to: []string{"hub:payroll", "hub:portal", "hub:analytics"},
		text: "ADR-001 принят: модель сотрудника общая, берите её из hrm-platform"},
	{stage: "hrm-core", from: "hub", to: []string{"backend"}, join: []demoAgent{{"backend", "codex", "gpt-6.1-sol", "API сотрудников"}},
		text: "@backend API сотрудников и оргструктуры по ADR-001, контракт OpenAPI"},
	{stage: "hrm-core", from: "watchdog", to: []string{"hub"}, join: []demoAgent{{"watchdog", "watchdog", "", "Сторож агентов"}},
		text: "Все агенты на связи, зависших нет"},
	// payroll
	{stage: "payroll", from: "hub", to: []string{"payroll-dev"}, join: []demoAgent{{"payroll-dev", "claude", "claude-sonnet-5-5", "Расчёт зарплаты"}},
		text: "@payroll-dev расчёт: оклад, премии, НДФЛ по прогрессивной шкале"},
	{stage: "payroll", from: "hub", to: []string{"tax-rules"}, join: []demoAgent{{"tax-rules", "codex", "gpt-6.1-sol", "Налоговый справочник"}},
		text: "@tax-rules ставки и вычеты — в справочник, без хардкода"},
	{stage: "payroll", from: "tax-rules", to: []string{"payroll-dev"}, done: []string{"tax-rules"},
		text: "Справочник готов: пять ступеней НДФЛ, вычеты на детей"},
	{stage: "payroll", from: "payroll-dev", to: []string{"hub"},
		text: "Месяц на 1 200 сотрудников считается за 3,4 с, эталон сошёлся"},
	// portal
	{stage: "portal", from: "hub", to: []string{"designer"}, join: []demoAgent{{"designer", "claude", "claude-opus-5-5", "Макеты портала"}},
		text: "@designer портал сотрудника: заявка на отпуск в три клика"},
	{stage: "portal", from: "designer", to: []string{"frontend"}, join: []demoAgent{{"frontend", "claude", "claude-sonnet-5-5", "Портал сотрудника"}},
		done: []string{"designer"}, text: "Макеты готовы: заявка, согласование, остаток дней отпуска"},
	{stage: "portal", from: "frontend", to: []string{"hub"},
		text: "Портал на стенде: вход через SSO, отпуска, мои документы"},
	// analytics
	{stage: "analytics", from: "hub", to: []string{"dbt"}, join: []demoAgent{{"dbt", "codex", "gpt-6.1-sol", "Витрины HR"}},
		text: "@dbt витрины: численность, текучесть, фонд оплаты труда"},
	{stage: "analytics", from: "dbt", to: []string{"hub"}, done: []string{"dbt"},
		text: "Витрины собраны, тесты dbt зелёные, текучесть за квартал 4,1 %"},
	// questions to the owner
	{stage: "payroll", from: "hub", to: []string{"owner"}, ask: 1,
		text: "Вопрос: премию относим к месяцу начисления или к месяцу выплаты?"},
	{stage: "portal", from: "hub", to: []string{"owner"}, ask: 1,
		text: "Вопрос: руководитель видит зарплаты подчинённых или только грейд?"},
	// review while the owner thinks
	{stage: "hrm-core", from: "hub", to: []string{"reviewer"}, join: []demoAgent{{"reviewer", "codex", "gpt-6-astra", "Ревью API"}},
		pause: 2, text: "@reviewer ревью API сотрудников: права доступа и маскирование"},
	{stage: "hrm-core", from: "reviewer", to: []string{"backend"},
		text: "Блокер: /employees отдаёт паспорт без маски для роли manager"},
	{stage: "hrm-core", from: "backend", to: []string{"reviewer"}, done: []string{"backend"},
		text: "Исправил: маска по ролям, тест на каждую роль"},
	{stage: "hrm-core", from: "reviewer", to: []string{"hub"}, done: []string{"reviewer"},
		text: "Повторное ревью: замечаний нет, можно мержить"},
	// the owner answers
	{stage: "payroll", from: "owner", to: []string{"hub"}, ask: -1,
		text: "К месяцу начисления, как в бухгалтерии"},
	{stage: "payroll", from: "payroll-dev", to: []string{"hub"}, done: []string{"payroll-dev"},
		text: "Перевёл премии на месяц начисления, сверка с 1С — до копейки"},
	{stage: "portal", from: "owner", to: []string{"hub"}, ask: -1,
		text: "Только грейд и вилку. Суммы видят HR и сам сотрудник"},
	{stage: "portal", from: "frontend", to: []string{"hub"},
		text: "Суммы скрыты у руководителя, у HR видны — проверено e2e"},
	// quality
	{stage: "portal", from: "hub", to: []string{"a11y"}, join: []demoAgent{{"a11y", "claude", "claude-haiku-5-5", "Доступность портала"}},
		text: "@a11y проверь портал на доступность"},
	{stage: "portal", from: "a11y", to: []string{"frontend"},
		text: "Контраст кнопок 3,8:1, нужно не меньше 4,5:1"},
	{stage: "portal", from: "frontend", to: []string{"a11y"}, done: []string{"frontend", "a11y"},
		text: "Поправил токены цвета, Lighthouse: доступность 100"},
	{stage: "payroll", from: "hub", to: []string{"qa"}, join: []demoAgent{{"qa", "codex", "gpt-6-luna", "Регресс расчёта"}},
		text: "@qa регресс расчёта за 12 месяцев на копии прод-данных"},
	{stage: "payroll", from: "qa", to: []string{"hub"}, done: []string{"qa"},
		text: "Регресс за 12 месяцев: расхождений 0, отчёт в CI"},
	{stage: "hrm-core", from: "hub", to: []string{"loadtest"}, join: []demoAgent{{"loadtest", "claude", "claude-haiku-5-5", "Нагрузочный тест"}},
		text: "@loadtest нагрузка: 5 000 сотрудников, 200 запросов в секунду"},
	{stage: "hrm-core", from: "loadtest", to: []string{"hub"}, done: []string{"loadtest"},
		text: "p95 140 мс при 200 rps; поиск был узким местом, добавил индекс"},
	{stage: "analytics", from: "hub", to: []string{"metrics"}, join: []demoAgent{{"metrics", "claude", "claude-sonnet-5-5", "Дашборд руководителя"}},
		text: "@metrics дашборд для CEO: численность, ФОТ, текучесть"},
	{stage: "analytics", from: "metrics", to: []string{"hub"}, done: []string{"metrics"},
		text: "Дашборд готов, данные обновляются каждый час"},
	// release
	{stage: "hrm-core", from: "hub", to: []string{"hub:payroll", "hub:portal", "hub:analytics"},
		text: "Релиз 1.0 в пятницу, заморозка кода в четверг в 18:00"},
	{stage: "payroll", from: "hub", to: []string{"hub:hrm-core"}, text: "payroll готов к релизу, CI зелёный"},
	{stage: "portal", from: "hub", to: []string{"hub:hrm-core"}, text: "portal готов, e2e и доступность пройдены"},
	{stage: "analytics", from: "hub", to: []string{"hub:hrm-core"}, text: "analytics готов, витрины на проде"},
	{stage: "hrm-core", from: "hub", to: []string{"owner"}, ask: 1,
		text: "HRM 1.0 готов: 4 модуля, 1 340 тестов зелёные. Выкатываем?"},
	{stage: "hrm-core", from: "owner", to: []string{"hub"}, ask: -1, pause: 4,
		text: "Выкатывай. Отличная работа, команда"},
	{stage: "hrm-core", from: "hub", to: []string{"hub:payroll", "hub:portal", "hub:analytics"},
		text: "HRM 1.0 на проде. Спасибо всем, воркеры свободны"},
}

type demoWorld struct {
	workers   map[string][]Worker // stage -> workers in arrival order
	questions map[string]int
	ctx       map[string]int
}

func (d *demoWorld) state(machine string) State {
	views := []StageView{}
	for _, s := range demoStages {
		ws := append([]Worker{}, d.workers[s.name]...)
		views = append(views, StageView{Name: s.name, Repo: s.repo, Open: true, Goal: s.goal, Workers: ws,
			Hub:       &HubInfo{Tag: "hub", Kind: "claude", Host: machine, Title: s.goal, Ctx: d.ctx[s.name]},
			Questions: d.questions[s.name]})
	}
	return State{Machine: machine, At: time.Now().Format(time.RFC3339), Stages: views}
}

func (d *demoWorld) engine(stage, role string) string {
	if role == "hub" {
		return "claude"
	}
	for _, w := range d.workers[stage] {
		if w.Role == role {
			return w.Engine
		}
	}
	return ""
}

func (d *demoWorld) setWorking(stage, role string, on bool) {
	for i := range d.workers[stage] {
		if d.workers[stage][i].Role == role {
			d.workers[stage][i].Working = on
		}
	}
}

func demoNode(stage, who string) Node {
	switch {
	case who == "owner":
		return Node{"*", "owner"}
	case strings.HasPrefix(who, "hub:"):
		return Node{strings.TrimPrefix(who, "hub:"), "hub"}
	}
	return Node{stage, who}
}

func (h *Hub) setDemo(d *demoWorld) {
	h.mu.Lock()
	h.state = d.state(h.machine)
	st := h.state
	h.mu.Unlock()
	h.publish("state", st)
}

// demoLoop plays the script forever: the hubs stay, the workers take off as they get work and land after the release.
func (h *Hub) demoLoop() {
	repo := map[string]string{}
	for _, s := range demoStages {
		repo[s.name] = s.repo
	}
	sleep := func(s float64) { time.Sleep(time.Duration(s * float64(time.Second))) }
	for {
		d := &demoWorld{workers: map[string][]Worker{}, questions: map[string]int{}, ctx: map[string]int{}}
		for _, s := range demoStages {
			d.ctx[s.name] = 120000
		}
		h.setDemo(d)
		for i, step := range demoScript {
			if i == 0 {
				sleep(2)
			} else {
				sleep(demoGap + step.pause)
			}
			for _, a := range step.join {
				d.workers[step.stage] = append(d.workers[step.stage], Worker{Role: a.role, Tag: a.role, Engine: a.engine,
					Model: a.model, Alive: true, Working: true, Title: a.title})
			}
			if len(step.join) > 0 {
				h.setDemo(d) // the cab takes off before the line reaches it
				sleep(1)
			}
			to := []Node{}
			for _, t := range step.to {
				to = append(to, demoNode(step.stage, t))
			}
			now := time.Now()
			from := demoNode(step.stage, step.from)
			ev := &Event{Stage: step.stage, Repo: repo[step.stage], Tag: step.from, Text: step.text, At: now.Format(time.RFC3339),
				From: from, To: to, at: now}
			if from[1] != "owner" {
				ev.Engine = d.engine(step.stage, step.from)
			}
			h.mu.Lock()
			h.demoLog = append(h.demoLog, ev)
			if len(h.demoLog) > 500 {
				h.demoLog = h.demoLog[len(h.demoLog)-500:]
			}
			h.mu.Unlock()
			h.publish("line", ev)
			for _, r := range step.done {
				d.setWorking(step.stage, r, false)
			}
			d.questions[step.stage] += step.ask
			d.ctx[step.stage] += 8000 + 150*len([]rune(step.text)) // about 350k, the tallest tower, at the release
			h.setDemo(d)
		}
		sleep(12) // the release sinks in; then the cabs land and the story starts over
		for _, s := range demoStages {
			d.workers[s.name] = nil
		}
		h.setDemo(d)
		sleep(10)
	}
}
