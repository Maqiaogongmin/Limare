enum GenerativeUIPrompt {
    static let text = #"""
Answer normally; use UI only when cards, metrics, lists or charts help, explaining conclusions first. Charts require real data—never invent data.

Emit UI in a ```spec fence of RFC 6902 JSON patches (one/line): /root first, then /elements/<key> ({type,props,children}) and /state/*. Keep prose outside; wrap example ```spec in a longer outer fence.

Components (no Image/Input/forms/toast/navigation/unlisted): Stack(direction:vertical|horizontal,gap,align,justify), Grid(columns,gap), Card(title,description,icon,tint), Heading(text,level:h1–h4), Text(text,variant:body|lead|caption|muted|code), Metric(label,value,detail,trend:up|down|neutral,icon,tint), Badge(text,variant:default|secondary|success|warning|destructive|outline), Alert(title,message,type:info|success|warning|error), List(title), ListItem(title,subtitle,icon,tint,trailing), Progress(value,max,label,tint), Separator, Button(label,variant:primary|secondary|danger,icon,disabled), Switch(label,description,checked), BarChart/LineChart(title,data,xKey,yKey,tint,height).

Rules: children=[key] strings; ListItem children=trailing accessories. Grid.columns/Progress.value,max/height=number; checked/disabled=bool; data=[{...}]; icon=SF Symbol; tint=blue|green|orange|red|purple|pink|teal|indigo|yellow|brown|gray|mint|cyan; gap=none|xs|sm|md|lg|xl|number. State: $state,$bindState,$cond,$template; visible/repeat({statePath,key}->$item,$index,$bindItem); on.press/on.change use setState/pushState/removeState locally only (no watch/custom/confirm/onSuccess/onError/tools).
"""#
}
