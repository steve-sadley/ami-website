-- =============================================================================
-- 0070: Publications and useful links (/resources)
--
-- Steve, 22 November 2026: bring the old site's content across. Its Support
-- section held HSE publications, the Asbestos Network technical appendices, the
-- ATaC personal monitoring form, useful links and Croner HR support. They are
-- one page now, every word editable on the Pages screen. Two appendices and the
-- form were files on the old site and are now in the site's assets.
--
-- The Support page's second card pointed straight at hse.gov.uk; it now leads
-- to this page. Only that card changes, and only if it still points at the HSE,
-- so an edit the office has made is left alone.
--
-- The old discussion forum page is not brought across: the new site has its own
-- forum. News, videos and the one event are data, imported separately
-- (db/seeds/old-site-import.sql).
--
-- Safe to run twice.
-- =============================================================================

insert into public.page_blocks (page_key, block_key, body, items, status, sort_order) values
  ('resources', 'banner_photo', '/assets/photo-survey.webp', null, 'published', 1690),
  ('resources', 'banner_heading', 'Publications and useful links', null, 'published', 1700),
  ('resources', 'banner_lede', 'HSE guidance, the Asbestos Network technical appendices, forms, other bodies in the industry and HR support for members.', null, 'published', 1710),
  ('resources', 'hse_heading', 'HSE publications', null, 'published', 1720),
  ('resources', 'hse', '<ul> <li><a href="https://www.hse.gov.uk/asbestos/essentials/">Asbestos essentials (HSG210)</a>: a task manual for building, maintenance and allied trades on non-licensed asbestos work</li> <li><a href="https://www.hse.gov.uk/pubns/books/hsg247.htm">Asbestos: the licensed contractors’ guide (HSG247)</a></li> <li><a href="https://www.hse.gov.uk/pubns/books/hsg33.htm">Health and safety in roof work (HSG33)</a></li> <li><a href="https://www.hse.gov.uk/pubns/books/hsg248.htm">Asbestos: the analysts’ guide (HSG248)</a>, second edition 2021</li> </ul>', null, 'published', 1730),
  ('resources', 'network_heading', 'Asbestos Network technical appendices', null, 'published', 1740),
  ('resources', 'network', '<p>Appendices to the minutes of the Asbestos Network (AN) Technical Working Group.</p> <ul> <li><a href="https://www.arca.org.uk/Download/Appendix%201a-21%20Asbestos%20Cleans-Environmental%20Cleaning.pdf">Appendix 1a/21: asbestos cleans (environmental cleaning)</a></li> <li><a href="https://www.arca.org.uk/Download/Appendix%202%20-19%20Calculating%20NPU%20air%20flow.pdf">Appendix 2/19: calculating NPU air flow</a></li> <li><a href="https://www.arca.org.uk/Download/Appendix%206-17%20Abrasive%20Blasting%20Removal%20Systems.pdf">Appendix 6/17: abrasive blasting removal systems</a></li> <li><a href="/assets/AN-Appendix-01-24-Handover-of-Enclosures-to-Analysts-for-4SC.pdf">Appendix 01/24: handover of enclosures to analysts for 4SC (site supervisor visual inspection and handover form)</a></li> <li><a href="/assets/AN-Appendix-02-24-Asbestos-Skips-Van-Waste-Compartments-and-Waste-Storage.pdf">Appendix 02/24: asbestos skips, van waste compartments, waste storage and movement on site</a></li> </ul>', null, 'published', 1750),
  ('resources', 'forms_heading', 'Forms', null, 'published', 1760),
  ('resources', 'forms', '<p>ATaC has produced a personal monitoring requisition form to support members and the industry. The form is read only: download it to enter your information.</p> <ul> <li><a href="/assets/ATaC-Personal-Monitoring-Requisition-Form.xlsx">ATaC personal monitoring requisition form (Excel)</a></li> </ul>', null, 'published', 1770),
  ('resources', 'links_heading', 'Useful links', null, 'published', 1780),
  ('resources', 'links', '<ul> <li><a href="https://www.hse.gov.uk/asbestos/licensing/index.htm">Asbestos licensing</a> (HSE)</li> <li><a href="https://www.hse.gov.uk/asbestos/">Asbestos health and safety</a> (HSE)</li> <li><a href="https://www.arca.org.uk/">Asbestos Removal Contractors Association</a> (ARCA)</li> <li><a href="https://www.atac.org.uk/asbestos-testing-and-consultancy-association">Asbestos Testing and Consultancy Association</a> (ATaC)</li> <li><a href="https://bandce.co.uk/products-services/occupational-health-schemes/">Constructing Better Health</a></li> <li><a href="https://demolition-nfdc.com/">National Federation of Demolition Contractors</a></li> <li><a href="https://www.rics.org/uk/">Royal Institution of Chartered Surveyors</a></li> <li><a href="https://www.ukas.com/">United Kingdom Accreditation Service</a> (UKAS)</li> <li><a href="https://ami.mypsatests.org.uk/">Prostate cancer testing</a> for AMI members</li> </ul>', null, 'published', 1790),
  ('resources', 'hr_heading', 'HR support from Croner', null, 'published', 1800),
  ('resources', 'hr', '<p>For over 80 years Croner has delivered business compliance services, and it supports over 14,000 UK businesses with HR, health and safety, and employment law advice.</p> <p><strong>A free business support helpline.</strong> As an AMI member you can use Croner’s telephone advice line, which supports employers of permanent employees, freelancers and self-employed workers on:</p> <ul> <li><strong>HR:</strong> conduct, sickness and absence, redundancy, dismissal, legislation changes and contracts</li> <li><strong>Health and safety:</strong> fire safety, environmental, legislation, hazard management, accident reporting, premises management, and the law and your responsibilities</li> <li><strong>Commercial legal:</strong> GDPR, data protection, commercial contracts, insolvency and property</li> </ul> <p><strong>15% AMI member discount on additional services.</strong> Croner provides bespoke contracts and handbooks, case-managed advice, staff management software, an employee assistance service, bespoke health and safety documentation, and employment law and health and safety insurance.</p> <p>Call Croner on <strong>0844 561 8133</strong> and quote <strong>935445</strong>, or visit the <a href="https://croner.co.uk/services/partnerships/asbestos-removal-contractors-association/">Croner website</a>.</p>', null, 'published', 1810)
on conflict (page_key, block_key) do nothing;

-- The six cards as the editor will see them; only the second is taken from here.
update public.page_blocks b
   set items = jsonb_set(b.items, '{1}', v.items->1)
  from (values ('support', 'resources', null, '[{"body": "Clear, practical guidance written for asbestos professionals and duty holders.", "href": "/guidance", "icon": "document", "title": "AMI guidance notes"}, {"body": "HSE guidance, the Asbestos Network technical appendices, forms, useful links and HR support.", "href": "/resources", "icon": "external", "title": "Publications and useful links"}, {"body": "Recorded seminars, webinars and Annual General Meeting sessions.", "href": "/videos", "icon": "video", "title": "Webinars and AGM"}, {"body": "Everything in the AMI calendar, from regional meetings to the AGM.", "href": "/news?kind=event", "icon": "calendar", "title": "Events and seminars"}, {"body": "What the CPD requirement asks for, how points are earned and how they are recorded.", "href": "/cpd-scheme", "icon": "award", "title": "Continuing development"}, {"body": "The public register, so a client or duty holder can confirm a membership themselves.", "href": "/register", "icon": "person", "title": "Check a membership"}]'::jsonb)) v(page_key, block_key, body, items)
 where b.page_key = v.page_key and b.block_key = v.block_key
   and b.items->1->>'href' = 'https://www.hse.gov.uk/asbestos/';
