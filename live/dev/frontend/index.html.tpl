<script>
const chat=document.getElementById('chat'),q=document.getElementById('q'),btn=document.getElementById('ask');
function bubble(t,c){const d=document.createElement('div');d.className='msg '+c;d.textContent=t;chat.appendChild(d);window.scrollTo(0,document.body.scrollHeight)}

let busy=false;
async function ask(){
  if (busy) return;
  const text=q.value.trim(); if(!text) return;
  bubble(text,'user'); q.value=''; busy=true; btn.disabled=true;
  try{
    const r = await fetch('/query', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body: JSON.stringify({q:text})
    });

    const ct = (r.headers.get('content-type') || '').toLowerCase();
    if (!r.ok) {
      const t = await r.text();
      throw new Error(`HTTP ${r.status} – ${t.slice(0,200)}`);
    }
    if (!ct.includes('application/json')) {
      const t = await r.text();
      throw new Error(`Non-JSON response – ${t.slice(0,200)}`);
    }

    const j = await r.json();
    bubble(j.answer || JSON.stringify(j),'bot');
    if (j.citations?.length) {
      bubble("Sources:\n- " + j.citations.map(x=>`${x.source} (p.${x.page||"?"})`).join("\n- "),'bot');
    }
  } catch(e){
    bubble("Error: " + e.message,'bot');
  } finally {
    setTimeout(()=>{busy=false; btn.disabled=false;}, 1200); // small cooldown to avoid throttling
  }
}
btn.onclick=ask; q.onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey) ask()};
</script>
